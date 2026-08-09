import Foundation

// Usage-display models are intentionally provider-agnostic. The Codex provider
// maps its backend rate-limit payload into these types.

public struct SwitcherooUsageWindow: Equatable, Sendable {
    /// Consumption reported by the backend (0-100 percent of the window used).
    public let usedPercent: Double
    /// Remaining allowance derived from `usedPercent` and clamped to 0-100.
    public let remainingPercent: Double
    /// Length of the window in seconds, when the backend provides it.
    public let windowSeconds: Int?
    /// Epoch time at which the window resets, when the backend provides it.
    public let resetsAt: Date?

    public init(usedPercent: Double, remainingPercent: Double, windowSeconds: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
    }
}

public struct SwitcherooAccountUsage: Equatable, Sendable {
    public let accountId: String
    public let fiveHour: SwitcherooUsageWindow?
    public let weekly: SwitcherooUsageWindow?
    public let planType: String?
    public let fetchedAt: Date

    public init(
        accountId: String,
        fiveHour: SwitcherooUsageWindow?,
        weekly: SwitcherooUsageWindow?,
        planType: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
        self.fetchedAt = fetchedAt
    }
}

/// Per-account usage display state, keyed by account id in app state.
public enum SwitcherooAccountUsageState: Equatable, Sendable {
    case notRequested
    case loading
    case loaded(SwitcherooAccountUsage)
    case unavailable(reason: String?)
}

/// Recoverable usage-display failures. Messages are deliberately secret-free:
/// no tokens, URLs, or request bodies ever appear in them.
public enum SwitcherooUsageError: LocalizedError, Sendable, Equatable {
    case noCredential
    case authenticationFailed
    case serviceUnavailable
    case networkUnavailable
    case malformedResponse

    public var errorDescription: String? {
        diagnosticMessage
    }

    /// Short, user-facing reason safe to show in the menu bar and logs.
    public var diagnosticMessage: String {
        switch self {
        case .noCredential:
            return "No saved credential for this account"
        case .authenticationFailed:
            return "Sign-in may have expired; re-login to refresh this account"
        case .serviceUnavailable:
            return "Usage service is busy or unavailable right now"
        case .networkUnavailable:
            return "Could not reach the usage service (offline?)"
        case .malformedResponse:
            return "Unexpected usage response from the service"
        }
    }
}
