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

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum CodexAPIClientError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidResponse
    case networkFailure
    case httpStatus(Int)
}

/// Injectable HTTP layer. Real calls use `URLSessionCodexTransport`; tests use
/// a mock so no live OpenAI request is ever made.
public protocol CodexHTTPTransport: Sendable {
    func perform(_ request: CodexAPIRequest) async throws -> CodexAPIResponse
}

/// Transport errors are normalized to `CodexAPIClientError.networkFailure` so
/// underlying error details (which can embed request URLs) never leak.
public struct URLSessionCodexTransport: CodexHTTPTransport {
    public let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func perform(_ request: CodexAPIRequest) async throws -> CodexAPIResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = timeoutSeconds
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw CodexAPIClientError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexAPIClientError.invalidResponse
        }
        return CodexAPIResponse(status: http.statusCode, body: data)
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
        guard let url = URL(string: "\(baseURL.absoluteString)\(pathStyle.pathPrefix)/\(path)") else {
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
            throw CodexAPIClientError.httpStatus(response.status)
        }
        return response.body
    }

    /// Extracts the bearer credential from a saved Codex `auth.json` snapshot.
    ///
    /// Mirrors the fields Codex itself uses for backend requests: the access
    /// token and, for ChatGPT logins, the account id for account routing.
    public static func credential(fromAuthData data: Data) -> CodexAPICredential? {
        guard
            let doc = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
            let accessToken = doc.tokens?.access_token,
            !accessToken.isEmpty
        else {
            return nil
        }
        return CodexAPICredential(
            accessToken: accessToken,
            accountId: doc.tokens?.account_id
        )
    }

    private struct CodexAuthFile: Decodable {
        struct Tokens: Decodable {
            var access_token: String?
            var account_id: String?
        }

        var tokens: Tokens?
    }
}
