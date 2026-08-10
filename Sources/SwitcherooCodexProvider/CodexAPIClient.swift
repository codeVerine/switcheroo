import Foundation

// Reusable authenticated base layer for first-party Codex backend APIs.
//
// It knows how to authenticate a request from a saved Codex auth snapshot and
// how to route to either the ChatGPT backend (`/wham/...`) or the Codex API
// (`/api/codex/...`) path families. Endpoint-specific clients (usage, and any
// future endpoints) build on top of it. Token refresh is intentionally out of
// scope: the layer uses the saved access token as-is so a later task can add
// refresh middleware without changing endpoint clients.

public struct CodexAPICredential: Sendable, Equatable {
    public let accessToken: String
    public let accountId: String?
    public let isFedrampAccount: Bool

    public init(accessToken: String, accountId: String? = nil, isFedrampAccount: Bool = false) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.isFedrampAccount = isFedrampAccount
    }
}

public enum CodexAPIPathStyle: Sendable, Equatable {
    /// ChatGPT backend API family: `{base}/wham/{path}` (default for Codex logins).
    case chatgpt
    /// Codex API family: `{base}/api/codex/{path}`.
    case codexApi

    public var pathPrefix: String {
        switch self {
        case .chatgpt:
            return "/wham"
        case .codexApi:
            return "/api/codex"
        }
    }
}

public struct CodexAPIRequest: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct CodexAPIResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    /// Response headers with lowercased names (used for Retry-After parsing).
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

public enum CodexAPIClientError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidResponse
    case networkFailure
    case httpStatus(Int, retryAfterSeconds: Int?)
}

/// Injectable HTTP layer. Real calls use `URLSessionCodexTransport`; tests use
/// a mock so no live OpenAI request is ever made.
public protocol CodexHTTPTransport: Sendable {
    func perform(_ request: CodexAPIRequest) async throws -> CodexAPIResponse
}

/// Transport errors are normalized to `CodexAPIClientError.networkFailure` so
/// underlying error details (which can embed request URLs) never leak.
///
/// The session is built from an ephemeral configuration with URL caching,
/// cookie storage, cookie acceptance, and URL credential storage all disabled,
/// so authenticated request/response data never touches a persistent
/// on-disk store - enforcing the documented memory-only retention policy.
public struct URLSessionCodexTransport: CodexHTTPTransport {
    public let timeoutSeconds: TimeInterval
    public let session: URLSession

    public init(timeoutSeconds: TimeInterval = 10, session: URLSession? = nil) {
        self.timeoutSeconds = timeoutSeconds
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeoutSeconds
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func perform(_ request: CodexAPIRequest) async throws -> CodexAPIResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CodexAPIClientError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexAPIClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let key = name as? String, let stringValue = value as? String {
                headers[key.lowercased()] = stringValue
            }
        }
        return CodexAPIResponse(status: http.statusCode, body: data, headers: headers)
    }
}

public struct CodexAPIClient: Sendable {
    public static let defaultChatGptBaseURL = URL(string: "https://chatgpt.com/backend-api")!
    public static let defaultCodexAPIBaseURL = URL(string: "https://api.openai.com")!

    public let baseURL: URL
    public let pathStyle: CodexAPIPathStyle

    private let transport: any CodexHTTPTransport
    private let userAgent: String

    public init(
        baseURL: URL,
        pathStyle: CodexAPIPathStyle,
        transport: any CodexHTTPTransport,
        userAgent: String = "switcheroo"
    ) {
        self.baseURL = baseURL
        self.pathStyle = pathStyle
        self.transport = transport
        self.userAgent = userAgent
    }

    /// Performs an authenticated GET against `{base}{pathPrefix}/{path}`.
    ///
    /// The credential is only ever placed in request headers, never in the URL
    /// or in any error the client produces.
    public func get(path: String, credential: CodexAPICredential) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.query == nil,
              components.fragment == nil,
              !path.contains("?") && !path.contains("#") else {
            throw CodexAPIClientError.invalidRequest
        }
        let segments = [components.path, pathStyle.pathPrefix, path]
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
        components.path = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            throw CodexAPIClientError.invalidRequest
        }

        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "User-Agent": userAgent,
        ]
        if let accountId = credential.accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-ID"] = accountId
        }
        if credential.isFedrampAccount {
            headers["X-OpenAI-Fedramp"] = "true"
        }

        let response: CodexAPIResponse
        do {
            response = try await transport.perform(CodexAPIRequest(url: url, headers: headers))
        } catch {
            throw CodexAPIClientError.networkFailure
        }

        guard response.status == 200 else {
            let retryAfterSeconds = Self.parseRetryAfter(response.headers["retry-after"])
            throw CodexAPIClientError.httpStatus(response.status, retryAfterSeconds: retryAfterSeconds)
        }
        return response.body
    }

    /// Parses a `Retry-After` header value: either delta seconds or an
    /// HTTP-date. Unparseable values yield `nil` (no server hint).
    private static func parseRetryAfter(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(trimmed), seconds >= 0 {
            return seconds
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let seconds = Int(date.timeIntervalSinceNow)
                return max(0, seconds)
            }
        }
        return nil
    }

    /// Extracts the bearer credential from a saved Codex `auth.json` snapshot.
    ///
    /// Mirrors the fields Codex itself uses for backend requests: the access
    /// token, the ChatGPT account id for account routing (falling back to the
    /// id-token claim when the explicit field is absent), and the FedRAMP
    /// routing flag derived from the saved id-token's
    /// `https://api.openai.com/auth` claims. The id-token is parsed into
    /// memory only and never retained or logged.
    public static func credential(fromAuthData data: Data) -> CodexAPICredential? {
        guard
            let doc = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
            let accessToken = doc.tokens?.access_token,
            !accessToken.isEmpty
        else {
            return nil
        }
        let authClaims = doc.tokens?.id_token.flatMap(jwtAuthClaims)
        let accountId = doc.tokens?.account_id ?? (authClaims?["chatgpt_account_id"] as? String)
        let isFedrampAccount = (authClaims?["chatgpt_account_is_fedramp"] as? Bool) ?? false
        return CodexAPICredential(
            accessToken: accessToken,
            accountId: accountId,
            isFedrampAccount: isFedrampAccount
        )
    }

    /// Decodes the `https://api.openai.com/auth` claims object from a JWT
    /// payload without verifying or retaining the token.
    private static func jwtAuthClaims(_ idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload += "="
        }
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["https://api.openai.com/auth"] as? [String: Any]
    }

    private struct CodexAuthFile: Decodable {
        struct Tokens: Decodable {
            var access_token: String?
            var account_id: String?
            var id_token: String?
        }

        var tokens: Tokens?
    }
}
