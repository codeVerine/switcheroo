import Foundation
import SwitcherooCore

// Fetches the Codex account usage endpoint used by the official Codex CLI:
//
//   GET {base}/wham/usage        (ChatGPT login, base = chatgpt.com/backend-api)
//   GET {base}/api/codex/usage   (Codex API style)
//
// Headers: `Authorization: Bearer <access token>` plus
// `ChatGPT-Account-ID: <account id>` when present in the saved auth snapshot.
//
// The response reports rate-limit windows as *consumption* (`used_percent`).
// The remaining allowance is derived as `clamp(100 - used_percent, 0, 100)`
// because the backend never reports a remaining value directly. The five-hour
// window is the payload's `rate_limit.primary_window` (18000s) and the weekly
// window is `rate_limit.secondary_window` (604800s); windows are classified by
// their reported `limit_window_seconds` with a primary/secondary fallback, the
// same duration-based labeling the Codex TUI uses.

public struct CodexUsageFetcher: AccountUsageFetching {
    private static let fiveHourSeconds = 5 * 60 * 60
    private static let weeklySeconds = 7 * 24 * 60 * 60
    private static let windowTolerance: Double = 0.05

    private let client: CodexAPIClient
    private let now: @Sendable () -> Date

    public init(client: CodexAPIClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    public func fetchUsage(authData: Data, accountId: String) async throws -> SwitcherooAccountUsage {
        guard let credential = CodexAPIClient.credential(fromAuthData: authData) else {
            throw SwitcherooUsageError.noCredential
        }

        let body: Data
        do {
            body = try await client.get(path: "usage", credential: credential)
        } catch let error as CodexAPIClientError {
            switch error {
            case .httpStatus(401, _), .httpStatus(403, _):
                throw SwitcherooUsageError.authenticationFailed
            case .httpStatus(429, let retryAfterSeconds):
                throw SwitcherooUsageError.serviceUnavailable(retryAfterSeconds: retryAfterSeconds)
            case .httpStatus(500, _), .httpStatus(502, _), .httpStatus(503, _), .httpStatus(504, _):
                throw SwitcherooUsageError.serviceUnavailable(retryAfterSeconds: nil)
            case .httpStatus:
                throw SwitcherooUsageError.serviceUnavailable(retryAfterSeconds: nil)
            case .networkFailure:
                throw SwitcherooUsageError.networkUnavailable
            case .invalidRequest, .invalidResponse:
                throw SwitcherooUsageError.malformedResponse
            }
        }

        guard let payload = try? JSONDecoder().decode(RateLimitStatusPayload.self, from: body) else {
            throw SwitcherooUsageError.malformedResponse
        }

        let usage = map(payload: payload, accountId: accountId)
        // A structurally empty 200 response has no usable window data; treat
        // it as malformed so the row shows unavailable instead of silently
        // removing the usage line. A single valid window is still fine.
        guard usage.fiveHour != nil || usage.weekly != nil else {
            throw SwitcherooUsageError.malformedResponse
        }
        return usage
    }

    func map(payload: RateLimitStatusPayload, accountId: String) -> SwitcherooAccountUsage {
        let rateLimit = payload.rateLimit

        let fiveHour = Self.classifiedWindow(
            windows: (
                primary: rateLimit?.primaryWindow,
                secondary: rateLimit?.secondaryWindow
            ),
            preferredSeconds: Self.fiveHourSeconds,
            primaryIsPreferred: true
        )
        let weekly = Self.classifiedWindow(
            windows: (
                primary: rateLimit?.primaryWindow,
                secondary: rateLimit?.secondaryWindow
            ),
            preferredSeconds: Self.weeklySeconds,
            primaryIsPreferred: false
        )

        return SwitcherooAccountUsage(
            accountId: accountId,
            fiveHour: fiveHour,
            weekly: weekly,
            planType: payload.planType,
            fetchedAt: now()
        )
    }

    /// Maps a backend window snapshot to a usage window, preferring the window
    /// whose reported duration matches `preferredSeconds` and falling back to
    /// the primary/secondary position when duration is unknown.
    private static func classifiedWindow(
        windows: (primary: RateLimitWindowSnapshot?, secondary: RateLimitWindowSnapshot?),
        preferredSeconds: Int,
        primaryIsPreferred: Bool
    ) -> SwitcherooUsageWindow? {
        if let primary = windows.primary, matchesDuration(primary, seconds: preferredSeconds) {
            return mapWindow(primary)
        }
        if let secondary = windows.secondary, matchesDuration(secondary, seconds: preferredSeconds) {
            return mapWindow(secondary)
        }
        // Duration unknown: trust the position the backend reported.
        if primaryIsPreferred, let primary = windows.primary {
            return mapWindow(primary)
        }
        if !primaryIsPreferred, let secondary = windows.secondary {
            return mapWindow(secondary)
        }
        return nil
    }

    private static func matchesDuration(_ window: RateLimitWindowSnapshot, seconds: Int) -> Bool {
        guard let reported = window.limitWindowSeconds, reported > 0 else { return false }
        let lower = Double(seconds) * (1 - windowTolerance)
        let upper = Double(seconds) * (1 + windowTolerance)
        return Double(reported) >= lower && Double(reported) <= upper
    }

    /// The backend reports consumption (`used_percent`); remaining allowance is
    /// derived and clamped to 0-100 because the API never reports it directly.
    private static func mapWindow(_ window: RateLimitWindowSnapshot) -> SwitcherooUsageWindow {
        let used = window.usedPercent
        let remaining = max(0, min(100, 100 - used))
        let resetsAt = window.resetAt.map { Date(timeIntervalSince1970: $0) }
        return SwitcherooUsageWindow(
            usedPercent: used,
            remainingPercent: remaining,
            windowSeconds: window.limitWindowSeconds,
            resetsAt: resetsAt
        )
    }
}

// Response model for the codex-backend `RateLimitStatusPayload` OpenAPI schema
// (only the fields Switcheroo displays). All optional fields decode leniently
// so schema drift degrades to "usage unavailable" instead of a crash.
public struct RateLimitStatusPayload: Decodable, Sendable {
    public let planType: String?
    public let rateLimit: RateLimitStatusDetails?

    public init(planType: String?, rateLimit: RateLimitStatusDetails?) {
        self.planType = planType
        self.rateLimit = rateLimit
    }

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

public struct RateLimitStatusDetails: Decodable, Sendable {
    public let primaryWindow: RateLimitWindowSnapshot?
    public let secondaryWindow: RateLimitWindowSnapshot?

    public init(primaryWindow: RateLimitWindowSnapshot?, secondaryWindow: RateLimitWindowSnapshot?) {
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

public struct RateLimitWindowSnapshot: Decodable, Sendable {
    public let usedPercent: Double
    public let limitWindowSeconds: Int?
    public let resetAt: TimeInterval?

    public init(usedPercent: Double, limitWindowSeconds: Int?, resetAt: TimeInterval?) {
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAt = resetAt
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
