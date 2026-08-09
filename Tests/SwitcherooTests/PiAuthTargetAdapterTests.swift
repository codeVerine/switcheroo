import XCTest
import SwitcherooCore
import SwitcherooPiAdapter

final class PiAuthTargetAdapterTests: XCTestCase {
    private var adapter: PiAuthTargetAdapter { PiAuthTargetAdapter() }

    // MARK: - Conversion

    func testConvertsValidCodexAuthToPiOAuthCredential() throws {
        let accessToken = makeJWT(payload: ["exp": 1_700_000_000])
        let authData = try makeCodexAuthData(
            accessToken: accessToken,
            refreshToken: "refresh-token-abc",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-42"]])
        )

        let credential = try adapter.convertedCredential(fromSourceAuthData: authData)

        XCTAssertEqual(credential.destinationKey, "openai-codex")
        guard case .object(let fields) = credential.jsonValue else {
            return XCTFail("Expected object credential")
        }
        XCTAssertEqual(fields["type"], .string("oauth"))
        XCTAssertEqual(fields["access"], .string(accessToken))
        XCTAssertEqual(fields["refresh"], .string("refresh-token-abc"))
        XCTAssertEqual(fields["expires"], .number(1_700_000_000 * 1000))
        XCTAssertEqual(fields["accountId"], .string("chatgpt-acct-42"))
    }

    func testConversionFallsBackToCodexAccountIdWhenIdTokenLacksClaim() throws {
        let authData = try makeCodexAuthData(
            idToken: makeJWT(payload: ["email": "person@example.com"]),
            tokensAccountId: "codex-acct-7"
        )

        let credential = try adapter.convertedCredential(fromSourceAuthData: authData)

        guard case .object(let fields) = credential.jsonValue else {
            return XCTFail("Expected object credential")
        }
        XCTAssertEqual(fields["accountId"], .string("codex-acct-7"))
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
        let data = try makeTokensData(["access_token": makeJWT(payload: ["exp": 1_700_000_000])])
        assertUnsupported(data, reasonContains: "no refresh token")
    }

    func testConversionRejectsMissingAccountId() throws {
        let data = try makeTokensData([
            "access_token": makeJWT(payload: ["exp": 1_700_000_000]),
            "refresh_token": "refresh",
            "id_token": makeJWT(payload: ["email": "person@example.com"]),
        ])
        assertUnsupported(data, reasonContains: "no account id")
    }

    func testConversionRejectsAccessTokenWithoutExpiry() throws {
        let data = try makeTokensData([
            "access_token": makeJWT(payload: ["sub": "no-expiry"]),
            "refresh_token": "refresh",
            "id_token": makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]]),
        ])
        assertUnsupported(data, reasonContains: "no expiry")
    }

    // MARK: - Document merge

    func testMergePreservesUnrelatedProvidersAndReplacesOnlyOpenaiCodex() throws {
        let accessToken = makeJWT(payload: ["exp": 1_700_000_000])
        let authData = try makeCodexAuthData(accessToken: accessToken, refreshToken: "refresh-token-abc")
        let existing = Data("""
        {
          "opencode-go": { "type": "api_key", "key": "placeholder-key" },
          "openai-codex": { "type": "oauth", "access": "old-access", "refresh": "old-refresh", "expires": 123, "accountId": "old-acct" }
        }
        """.utf8)

        let merged = try adapter.destinationDocument(fromSourceAuthData: authData, existingDestinationData: existing)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["openai-codex", "opencode-go"])
        let codex = try XCTUnwrap(object["openai-codex"] as? [String: Any])
        XCTAssertEqual(codex["type"] as? String, "oauth")
        XCTAssertEqual(codex["access"] as? String, accessToken)
        XCTAssertEqual(codex["refresh"] as? String, "refresh-token-abc")
        XCTAssertEqual(codex["expires"] as? Double, 1_700_000_000 * 1000)
        XCTAssertEqual(codex["accountId"] as? String, "chatgpt-acct-1")
        let other = try XCTUnwrap(object["opencode-go"] as? [String: Any])
        XCTAssertEqual(other["key"] as? String, "placeholder-key")
    }

    func testMergeCreatesDocumentWhenDestinationAbsent() throws {
        let authData = try makeCodexAuthData()

        let merged = try adapter.destinationDocument(fromSourceAuthData: authData, existingDestinationData: nil)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["openai-codex"])
    }

    func testMergeRejectsMalformedDestinationDocuments() throws {
        let authData = try makeCodexAuthData()

        let malformed: [Data] = [
            Data("not-json".utf8),
            Data("[1, 2, 3]".utf8),
            Data("\"a string\"".utf8),
            Data("".utf8),
        ]

        for data in malformed {
            XCTAssertThrowsError(try adapter.destinationDocument(fromSourceAuthData: authData, existingDestinationData: data)) { error in
                guard case AuthTargetSyncError.malformedDestination(let targetId, _) = error else {
                    return XCTFail("Expected malformedDestination, got \(error)")
                }
                XCTAssertEqual(targetId, "pi")
            }
        }
    }

    // MARK: - Diagnostics

    func testErrorMessagesNeverContainCredentialMaterial() throws {
        let secretAccess = "SECRET-ACCESS-TOKEN-VALUE"
        let secretRefresh = "SECRET-REFRESH-TOKEN-VALUE"
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "secret_claim": secretAccess]),
            refreshToken: secretRefresh,
            idToken: makeJWT(payload: ["email": "person@example.com"]),
            tokensAccountId: nil
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
