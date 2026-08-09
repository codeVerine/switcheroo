import XCTest
@testable import SwitcherooCodexProvider
import SwitcherooCore

final class MockCodexHTTPTransport: CodexHTTPTransport, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int = 200
        var body: Data = Data()
    }

    private let lock = NSLock()
    private var stub = Stub()
    private var error: Error?
    private var recordedRequests: [CodexAPIRequest] = []

    var requests: [CodexAPIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func setResponse(status: Int, body: Data) {
        lock.lock()
        stub = Stub(status: status, body: body)
        error = nil
        lock.unlock()
    }

    func setError(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func perform(_ request: CodexAPIRequest) async throws -> CodexAPIResponse {
        let (stub, error) = record(request)
        if let error {
            throw error
        }
        return CodexAPIResponse(status: stub.status, body: stub.body)
    }

    private func record(_ request: CodexAPIRequest) -> (Stub, Error?) {
        lock.lock()
        recordedRequests.append(request)
        let stub = stub
        let error = error
        lock.unlock()
        return (stub, error)
    }
}

final class CodexAPIClientTests: XCTestCase {
    private let credential = CodexAPICredential(accessToken: "tok-123", accountId: "acct-1")

    func makeClient(baseURL: URL, style: CodexAPIPathStyle, transport: MockCodexHTTPTransport) -> CodexAPIClient {
        CodexAPIClient(baseURL: baseURL, pathStyle: style, transport: transport)
    }

    func testChatGptPathStyleBuildsWhamUsageRequestWithAuthHeaders() async throws {
        let transport = MockCodexHTTPTransport()
        transport.setResponse(status: 200, body: Data("{}".utf8))
        let client = makeClient(baseURL: CodexAPIClient.defaultChatGptBaseURL, style: .chatgpt, transport: transport)

        _ = try await client.get(path: "usage", credential: credential)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok-123")
        XCTAssertEqual(request.headers["ChatGPT-Account-ID"], "acct-1")
        XCTAssertFalse(request.url.absoluteString.contains("tok-123"))
        XCTAssertFalse(request.url.absoluteString.contains("acct-1"))
    }

    func testCodexApiPathStyleBuildsApiCodexUsageRequest() async throws {
        let transport = MockCodexHTTPTransport()
        transport.setResponse(status: 200, body: Data("{}".utf8))
        let client = makeClient(baseURL: CodexAPIClient.defaultCodexAPIBaseURL, style: .codexApi, transport: transport)

        _ = try await client.get(path: "usage", credential: credential)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/api/codex/usage")
    }

    func testAccountIdHeaderOmittedWhenCredentialHasNoAccountId() async throws {
        let transport = MockCodexHTTPTransport()
        transport.setResponse(status: 200, body: Data("{}".utf8))
        let client = makeClient(baseURL: CodexAPIClient.defaultChatGptBaseURL, style: .chatgpt, transport: transport)

        _ = try await client.get(
            path: "usage",
            credential: CodexAPICredential(accessToken: "tok-123", accountId: nil)
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(request.headers["ChatGPT-Account-ID"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok-123")
    }

    func testNonSuccessStatusThrowsHttpStatusError() async {
        let transport = MockCodexHTTPTransport()
        transport.setResponse(status: 401, body: Data("unauthorized".utf8))
        let client = makeClient(baseURL: CodexAPIClient.defaultChatGptBaseURL, style: .chatgpt, transport: transport)

        do {
            _ = try await client.get(path: "usage", credential: credential)
            XCTFail("expected httpStatus error")
        } catch let error as CodexAPIClientError {
            XCTAssertEqual(error, .httpStatus(401))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTransportFailureMapsToNetworkFailure() async {
        let transport = MockCodexHTTPTransport()
        transport.setError(URLError(.notConnectedToInternet))
        let client = makeClient(baseURL: CodexAPIClient.defaultChatGptBaseURL, style: .chatgpt, transport: transport)

        do {
            _ = try await client.get(path: "usage", credential: credential)
            XCTFail("expected networkFailure error")
        } catch let error as CodexAPIClientError {
            XCTAssertEqual(error, .networkFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCredentialParsingFromAuthSnapshot() throws {
        let data = try makeCodexAuthData(accessToken: "tok-456", accountId: "acct-9")
        let credential = CodexAPIClient.credential(fromAuthData: data)
        XCTAssertEqual(credential, CodexAPICredential(accessToken: "tok-456", accountId: "acct-9"))
    }

    func testCredentialParsingMissingAccessTokenReturnsNil() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": "acct-1"]])
        XCTAssertNil(CodexAPIClient.credential(fromAuthData: data))
        XCTAssertNil(CodexAPIClient.credential(fromAuthData: Data("not json".utf8)))
    }
}

final class CodexUsageFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let transport = MockCodexHTTPTransport()

    func makeFetcher() -> CodexUsageFetcher {
        let client = CodexAPIClient(
            baseURL: CodexAPIClient.defaultChatGptBaseURL,
            pathStyle: .chatgpt,
            transport: transport
        )
        let fixedNow = now
        return CodexUsageFetcher(client: client, now: { fixedNow })
    }

    private func payload(
        primaryUsed: Int? = 42,
        primarySeconds: Int? = 18_000,
        primaryReset: TimeInterval? = 1_700_100_000,
        secondaryUsed: Int? = 84,
        secondarySeconds: Int? = 604_800,
        secondaryReset: TimeInterval? = 1_705_000_000,
        planType: String = "pro"
    ) -> Data {
        var rateLimit: [String: Any] = ["allowed": true, "limit_reached": false]
        if let primaryUsed {
            var window: [String: Any] = ["used_percent": primaryUsed]
            if let primarySeconds { window["limit_window_seconds"] = primarySeconds }
            if let primaryReset { window["reset_at"] = primaryReset }
            rateLimit["primary_window"] = window
        }
        if let secondaryUsed {
            var window: [String: Any] = ["used_percent": secondaryUsed]
            if let secondarySeconds { window["limit_window_seconds"] = secondarySeconds }
            if let secondaryReset { window["reset_at"] = secondaryReset }
            rateLimit["secondary_window"] = window
        }
        let payload: [String: Any] = [
            "plan_type": planType,
            "rate_limit": rateLimit,
            "credits": ["has_credits": true, "unlimited": false, "balance": "9.99"],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func authData() throws -> Data {
        try makeCodexAuthData(accessToken: "tok-123", accountId: "acct-1")
    }

    func testFetchMapsFiveHourAndWeeklyWindowsWithResetTiming() async throws {
        transport.setResponse(status: 200, body: payload())
        let fetcher = makeFetcher()

        let usage = try await fetcher.fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertEqual(usage.accountId, "acct-1")
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.fetchedAt, now)

        let fiveHour = try XCTUnwrap(usage.fiveHour)
        XCTAssertEqual(fiveHour.usedPercent, 42)
        XCTAssertEqual(fiveHour.remainingPercent, 58)
        XCTAssertEqual(fiveHour.windowSeconds, 18_000)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_700_100_000))

        let weekly = try XCTUnwrap(usage.weekly)
        XCTAssertEqual(weekly.usedPercent, 84)
        XCTAssertEqual(weekly.remainingPercent, 16)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_705_000_000))
    }

    func testFractionalUsedPercentDecodesWithoutError() async throws {
        let fractional = try JSONSerialization.data(withJSONObject: [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 57.5, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 12.25, "limit_window_seconds": 604_800],
            ],
        ])
        transport.setResponse(status: 200, body: fractional)

        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertEqual(usage.fiveHour?.usedPercent, 57.5)
        XCTAssertEqual(usage.fiveHour?.remainingPercent, 42.5)
        XCTAssertEqual(usage.weekly?.usedPercent, 12.25)
        XCTAssertEqual(usage.weekly?.remainingPercent, 87.75)
    }

    func testRemainingIsDerivedFromConsumptionAndClamped() async throws {
        transport.setResponse(status: 200, body: payload(primaryUsed: 120, secondaryUsed: -5))
        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertEqual(usage.fiveHour?.remainingPercent, 0)
        XCTAssertEqual(usage.weekly?.remainingPercent, 100)
    }

    func testWindowsClassifiedByDurationEvenWhenPositionsSwapped() async throws {
        // Secondary carries the 5h window; primary carries the weekly window.
        transport.setResponse(
            status: 200,
            body: payload(primaryUsed: 10, primarySeconds: 604_800, secondaryUsed: 60, secondarySeconds: 18_000)
        )

        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertEqual(usage.fiveHour?.usedPercent, 60)
        XCTAssertEqual(usage.fiveHour?.windowSeconds, 18_000)
        XCTAssertEqual(usage.weekly?.usedPercent, 10)
        XCTAssertEqual(usage.weekly?.windowSeconds, 604_800)
    }

    func testWindowsFallBackToPrimarySecondaryPositionsWhenDurationUnknown() async throws {
        transport.setResponse(
            status: 200,
            body: payload(primaryUsed: 11, primarySeconds: 0, secondaryUsed: 22, secondarySeconds: nil)
        )

        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertEqual(usage.fiveHour?.usedPercent, 11)
        XCTAssertEqual(usage.weekly?.usedPercent, 22)
        XCTAssertEqual(usage.fiveHour?.windowSeconds, 0)
        XCTAssertNil(usage.weekly?.windowSeconds)
    }

    func testMissingRateLimitProducesUsageWithNoWindows() async throws {
        transport.setResponse(status: 200, body: Data("{\"plan_type\": \"pro\"}".utf8))
        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.weekly)
    }

    func testMissingResetAtProducesNilResetsAt() async throws {
        let noReset = try JSONSerialization.data(withJSONObject: [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 42, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 84, "limit_window_seconds": 604_800],
            ],
        ])
        transport.setResponse(status: 200, body: noReset)
        let usage = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")

        XCTAssertNil(usage.fiveHour?.resetsAt)
        XCTAssertNil(usage.weekly?.resetsAt)
    }

    func testMalformedBodyThrowsMalformedResponse() async {
        transport.setResponse(status: 200, body: Data("not json".utf8))
        do {
            _ = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")
            XCTFail("expected malformedResponse")
        } catch let error as SwitcherooUsageError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnauthorizedStatusThrowsAuthenticationFailed() async {
        transport.setResponse(status: 401, body: Data("{}".utf8))
        do {
            _ = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")
            XCTFail("expected authenticationFailed")
        } catch let error as SwitcherooUsageError {
            XCTAssertEqual(error, .authenticationFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRateLimitedStatusThrowsServiceUnavailable() async {
        transport.setResponse(status: 429, body: Data("{}".utf8))
        do {
            _ = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")
            XCTFail("expected serviceUnavailable")
        } catch let error as SwitcherooUsageError {
            XCTAssertEqual(error, .serviceUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNetworkFailureThrowsNetworkUnavailable() async {
        transport.setError(CodexAPIClientError.networkFailure)
        do {
            _ = try await makeFetcher().fetchUsage(authData: try authData(), accountId: "acct-1")
            XCTFail("expected networkUnavailable")
        } catch let error as SwitcherooUsageError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInvalidAuthDataThrowsNoCredential() async {
        transport.setResponse(status: 200, body: payload())
        do {
            _ = try await makeFetcher().fetchUsage(authData: Data("junk".utf8), accountId: "acct-1")
            XCTFail("expected noCredential")
        } catch let error as SwitcherooUsageError {
            XCTAssertEqual(error, .noCredential)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
