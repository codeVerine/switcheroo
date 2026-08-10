import XCTest
import SwitcherooCore
@testable import SwitcherooPiAdapter

final class PiAuthTargetAdapterTests: XCTestCase {
    private var adapter: PiAuthTargetAdapter { PiAuthTargetAdapter() }

    // MARK: - Conversion

    func testConvertsValidCodexAuthToPiOAuthCredential() throws {
        let accessToken = makeJWT(payload: [
            "exp": 1_700_000_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-42"],
        ])
        let authData = try makeCodexAuthData(
            accessToken: accessToken,
            refreshToken: "refresh-token-abc",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-42"]])
        )

        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))

        XCTAssertEqual(credential.destinationKey, "openai-codex")
        guard case .object(let fields) = credential.jsonValue else {
            return XCTFail("Expected object credential")
        }
        XCTAssertEqual(fields["type"], .string("oauth"))
        XCTAssertEqual(fields["access"], .string(accessToken))
        XCTAssertEqual(fields["refresh"], .string("refresh-token-abc"))
        XCTAssertEqual(fields["expires"], .integer(1_700_000_000 * 1000))
        XCTAssertEqual(fields["accountId"], .string("chatgpt-acct-42"))
    }

    func testConversionUsesAccessTokenAccountIdWhenIdTokenHasNoClaim() throws {
        let authData = try makeCodexAuthData(idToken: makeJWT(payload: ["email": "person@example.com"]))

        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))

        guard case .object(let fields) = credential.jsonValue else {
            return XCTFail("Expected object credential")
        }
        XCTAssertEqual(fields["accountId"], .string("chatgpt-acct-1"))
    }

    func testConversionRejectsAccessTokenWithoutChatgptAccountIdClaim() throws {
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "sub": "no-account-claim"]),
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"]])
        )
        assertUnsupported(authData, reasonContains: "no chatgpt_account_id claim")
    }

    func testConversionRejectsConflictingIdTokenAccountId() throws {
        let authData = try makeCodexAuthData(
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "other-account"]])
        )
        assertUnsupported(authData, reasonContains: "conflicting account ids")
    }

    func testConversionRejectsConflictingTokensAccountId() throws {
        let authData = try makeCodexAuthData(tokensAccountId: "other-account")
        assertUnsupported(authData, reasonContains: "conflicting account ids")
    }

    func testConversionRejectsNonJSONSource() {
        assertUnsupported(Data("not-json".utf8), reasonContains: "not a Codex auth.json")
    }

    func testConversionRejectsSourceWithoutTokens() throws {
        let data = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt"])
        assertUnsupported(data, reasonContains: "not a Codex auth.json")
    }

    func testConversionRejectsMissingAccessToken() throws {
        let data = try makeTokensData(["refresh_token": "refresh", "id_token": makeJWT(payload: ["email": "x@example.com"])])
        assertUnsupported(data, reasonContains: "no access token")
    }

    func testConversionRejectsMissingRefreshToken() throws {
        let data = try makeTokensData(["access_token": makeJWT(payload: [
            "exp": 1_700_000_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
        ])])
        assertUnsupported(data, reasonContains: "no refresh token")
    }

    func testConversionRejectsAccessTokenWithoutExpiry() throws {
        let data = try makeTokensData([
            "access_token": makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"]]),
            "refresh_token": "refresh",
        ])
        assertUnsupported(data, reasonContains: "no expiry")
    }

    func testConversionRejectsOutOfRangeExpiry() throws {
        let data = try makeTokensData([
            "access_token": makeJWT(payload: [
                "exp": 1e20,
                "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
            ]),
            "refresh_token": "refresh",
        ])

        assertUnsupported(data, reasonContains: "expiry is out of range")
    }

    // MARK: - Locked publication

    func testWriteDestinationPreservesUnrelatedProvidersAndReplacesOnlyOpenaiCodex() throws {
        let accessToken = makeJWT(payload: [
            "exp": 1_700_000_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
        ])
        let authData = try makeCodexAuthData(accessToken: accessToken, refreshToken: "refresh-token-abc")
        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))
        let fileIO = InMemoryFileIO()
        let path = "~/.pi/agent/auth.json"
        fileIO.files[path] = Data("""
        {
          "opencode-go": { "type": "api_key", "key": "placeholder-key" },
          "openai-codex": { "type": "oauth", "access": "old-access", "refresh": "old-refresh", "expires": 123, "accountId": "old-acct" }
        }
        """.utf8)

        let written = try adapter.writeDestination(credential: credential, sourceAuthData: authData, destinationPath: path, fileIO: fileIO)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written.writtenData) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["openai-codex", "opencode-go"])
        let codex = try XCTUnwrap(object["openai-codex"] as? [String: Any])
        XCTAssertEqual(codex["type"] as? String, "oauth")
        XCTAssertEqual(codex["access"] as? String, accessToken)
        XCTAssertEqual(codex["refresh"] as? String, "refresh-token-abc")
        XCTAssertEqual(codex["expires"] as? Double, 1_700_000_000 * 1000)
        XCTAssertEqual(codex["accountId"] as? String, "chatgpt-acct-1")
        let other = try XCTUnwrap(object["opencode-go"] as? [String: Any])
        XCTAssertEqual(other["key"] as? String, "placeholder-key")
        XCTAssertEqual(fileIO.files[path], written.writtenData)
    }

    func testWriteDestinationCreatesDocumentWhenDestinationAbsent() throws {
        let authData = try makeCodexAuthData()
        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))
        let fileIO = InMemoryFileIO()

        let written = try adapter.writeDestination(credential: credential, sourceAuthData: authData, destinationPath: "~/.pi/agent/auth.json", fileIO: fileIO)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written.writtenData) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["openai-codex"])
    }

    func testWriteDestinationFailsWhenAnotherProcessHoldsTheLock() throws {
        let originalDeadline = PiAuthFileLock.acquireDeadline
        let originalPollInterval = PiAuthFileLock.pollInterval
        PiAuthFileLock.acquireDeadline = 0.2
        PiAuthFileLock.pollInterval = 0.01
        defer {
            PiAuthFileLock.acquireDeadline = originalDeadline
            PiAuthFileLock.pollInterval = originalPollInterval
        }

        let authData = try makeCodexAuthData()
        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))
        let fileIO = InMemoryFileIO()
        let path = "~/.pi/agent/auth.json"
        try fileIO.createDirectoryExclusive(path: "\(path).lock")

        XCTAssertThrowsError(try adapter.writeDestination(credential: credential, sourceAuthData: authData, destinationPath: path, fileIO: fileIO)) { error in
            guard case AuthTargetSyncError.destinationWriteFailed(let targetId, _, _) = error else {
                return XCTFail("Expected destinationWriteFailed, got \(error)")
            }
            XCTAssertEqual(targetId, "pi")
        }
    }

    func testWriteDestinationBreaksStaleLocks() throws {
        let authData = try makeCodexAuthData()
        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))
        let fileIO = InMemoryFileIO()
        let path = "~/.pi/agent/auth.json"
        try fileIO.createDirectoryExclusive(path: "\(path).lock")
        fileIO.modificationDates["\(path).lock"] = Date(timeIntervalSinceNow: -120)

        let written = try adapter.writeDestination(credential: credential, sourceAuthData: authData, destinationPath: path, fileIO: fileIO)

        XCTAssertFalse(fileIO.itemExists(path: "\(path).lock"))
        XCTAssertFalse((try JSONSerialization.jsonObject(with: written.writtenData) as? [String: Any])?.isEmpty ?? true)
    }

    func testLockHeartbeatRefreshesOwnership() throws {
        let originalStaleThreshold = PiAuthFileLock.staleThreshold
        let originalHeartbeatInterval = PiAuthFileLock.heartbeatInterval
        PiAuthFileLock.staleThreshold = 0.12
        PiAuthFileLock.heartbeatInterval = 0.02
        defer {
            PiAuthFileLock.staleThreshold = originalStaleThreshold
            PiAuthFileLock.heartbeatInterval = originalHeartbeatInterval
        }

        let fileIO = InMemoryFileIO()
        let lockPath = "~/.pi/agent/auth.json.lock"
        let lock = try PiAuthFileLock.acquire(path: "~/.pi/agent/auth.json", fileIO: fileIO)
        defer { lock.release() }
        let initialDate = try XCTUnwrap(fileIO.modificationDate(path: lockPath))
        let deadline = Date().addingTimeInterval(0.5)
        var refreshedDate = initialDate
        while refreshedDate <= initialDate && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            refreshedDate = try XCTUnwrap(fileIO.modificationDate(path: lockPath))
        }

        XCTAssertGreaterThan(refreshedDate, initialDate)
    }

    // MARK: - Destination validation

    func testValidationRejectsMalformedDestinationDocuments() throws {
        let malformed: [Data] = [
            Data("not-json".utf8),
            Data("[1, 2, 3]".utf8),
            Data("\"a string\"".utf8),
            Data("".utf8),
        ]

        for data in malformed {
            XCTAssertThrowsError(try adapter.validateExistingDestination(existingDestinationData: data, destinationPath: "~/.pi/agent/auth.json")) { error in
                guard case AuthTargetSyncError.malformedDestination(let targetId, _) = error else {
                    return XCTFail("Expected malformedDestination, got \(error)")
                }
                XCTAssertEqual(targetId, "pi")
            }
        }
    }

    func testValidationAcceptsAbsentAndValidDocuments() throws {
        try adapter.validateExistingDestination(existingDestinationData: nil, destinationPath: "~/.pi/agent/auth.json")
        try adapter.validateExistingDestination(existingDestinationData: Data(#"{"opencode-go": {}}"#.utf8), destinationPath: "~/.pi/agent/auth.json")
    }

    // MARK: - Exact number preservation (unrelated provider fields)

    func testMergePreservesExactIntegerValues() throws {
        let authData = try makeCodexAuthData()
        let credential = try XCTUnwrap(adapter.convertedCredential(fromSourceAuthData: authData))
        let fileIO = InMemoryFileIO()
        let path = "~/.pi/agent/auth.json"
        fileIO.files[path] = Data("""
        {
          "other-provider": {
            "big-integer": 9007199254740993,
            "negative": -9223372036854775808,
            "decimal": 1.5,
            "nested": { "deep": [1, 9007199254740994, 2.5] }
          }
        }
        """.utf8)

        let written = try adapter.writeDestination(credential: credential, sourceAuthData: authData, destinationPath: path, fileIO: fileIO)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written.writtenData) as? [String: Any])
        let other = try XCTUnwrap(object["other-provider"] as? [String: Any])
        XCTAssertEqual(other["big-integer"] as? Int64, 9_007_199_254_740_993)
        XCTAssertEqual(other["negative"] as? Int64, Int64.min)
        XCTAssertEqual(other["decimal"] as? Double, 1.5)
        let nested = try XCTUnwrap(other["nested"] as? [String: Any])
        let deep = try XCTUnwrap(nested["deep"] as? [Any])
        XCTAssertEqual(deep[0] as? Int64, 1)
        XCTAssertEqual(deep[1] as? Int64, 9_007_199_254_740_994)
        XCTAssertEqual(deep[2] as? Double, 2.5)
    }

    // MARK: - Diagnostics

    func testErrorMessagesNeverContainCredentialMaterial() throws {
        let secretAccess = "SECRET-ACCESS-TOKEN-VALUE"
        let secretRefresh = "SECRET-REFRESH-TOKEN-VALUE"
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: [
                "exp": 1_700_000_000,
                "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
                "secret_claim": secretAccess,
            ]),
            refreshToken: secretRefresh,
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "conflicting-account"]])
        )

        XCTAssertThrowsError(try adapter.convertedCredential(fromSourceAuthData: authData)) { error in
            let message = error.localizedDescription
            XCTAssertFalse(message.contains(secretAccess))
            XCTAssertFalse(message.contains(secretRefresh))
        }
    }

    // MARK: - Destination resolution

    func testDestinationPathDefaultsToPiAgentDir() {
        XCTAssertEqual(adapter.destinationAuthFilePath(forProviderState: SwitcherooProvider(id: "codex")), "~/.pi/agent/auth.json")
    }

    func testDestinationPathHonorsPiCodingAgentDirEnvOverride() throws {
        let previous = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", "/tmp/pi-agent-test", 1)
        defer {
            if let previous {
                setenv("PI_CODING_AGENT_DIR", previous, 1)
            } else {
                unsetenv("PI_CODING_AGENT_DIR")
            }
        }

        XCTAssertEqual(adapter.destinationAuthFilePath(forProviderState: SwitcherooProvider(id: "codex")), "/tmp/pi-agent-test/auth.json")
    }

    // MARK: - Helpers

    private func assertUnsupported(
        _ data: Data,
        reasonContains: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try adapter.convertedCredential(fromSourceAuthData: data), file: file, line: line) { error in
            guard case AuthTargetSyncError.unsupportedSource(let targetId, let reason) = error else {
                return XCTFail("Expected unsupportedSource, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(targetId, "pi", file: file, line: line)
            XCTAssertTrue(reason.contains(reasonContains), "Reason: \(reason)", file: file, line: line)
        }
    }

    private func makeTokensData(_ tokens: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": tokens])
    }
}
