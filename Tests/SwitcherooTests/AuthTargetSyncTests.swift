import XCTest
import SwitcherooCore
import SwitcherooPiAdapter

/// Behavioral tests for auth-target synchronization orchestration: the switch
/// flow converts the active Codex snapshot for every configured target adapter,
/// writes target auth files atomically with user-only permissions, preserves
/// unrelated destination entries, and rolls back the switch when a target write
/// or conversion fails.
final class AuthTargetSyncTests: XCTestCase {
    private let activeAuthPath = "/tmp/active/auth.json"
    private let piAuthPath = "~/.pi/agent/auth.json"

    // MARK: - Successful switching

    func testSwitchSynchronizesPiCredentialAndPreservesUnrelatedProviders() throws {
        let (harness, _, secondId, firstAuth, secondAuth) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.files[piAuthPath] = Data("""
        {
          "opencode-go": { "type": "api_key", "key": "placeholder-key" }
        }
        """.utf8)

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        // Codex active file switched.
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], secondAuth)

        // Pi auth file: openai-codex replaced, unrelated provider preserved.
        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex", "opencode-go"])
        let codex = try XCTUnwrap(piDoc["openai-codex"] as? [String: Any])
        XCTAssertEqual(codex["type"] as? String, "oauth")
        XCTAssertEqual(codex["refresh"] as? String, "refresh-second")
        XCTAssertEqual(codex["expires"] as? Double, 1_700_000_200 * 1000)
        XCTAssertEqual(codex["accountId"] as? String, "acct-second")
        let other = try XCTUnwrap(piDoc["opencode-go"] as? [String: Any])
        XCTAssertEqual(other["key"] as? String, "placeholder-key")

        XCTAssertEqual(harness.fileIO.publishedWrites.last?.path, piAuthPath)
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.permissions, 0o600)

        // Config marks the second account active.
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        XCTAssertEqual(savedConfig.providers.first?.activeAccountId, secondId)
        XCTAssertNotEqual(firstAuth, secondAuth)
    }

    func testSwitchCreatesTargetAuthFileWhenAbsent() throws {
        let (harness, _, secondId, _, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex"])
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.path, piAuthPath)
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.permissions, 0o600)
    }

    func testSwitchRunsEveryConfiguredTargetAdapter() throws {
        let stub = StubAuthTargetAdapter(
            id: "stub-harness",
            defaultDestinationAuthFilePath: "~/.stub-harness/auth.json"
        )
        let (harness, _, secondId, _, secondAuth) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter(), stub]
        )
        harness.fileIO.files[piAuthPath] = Data(#"{"opencode-go": {"type": "api_key"}}"#.utf8)
        harness.fileIO.files["~/.stub-harness/auth.json"] = Data(#"{"unrelated": {"keep": true}}"#.utf8)

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        XCTAssertEqual(stub.documentCalls, 1)
        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex", "opencode-go"])
        let stubDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files["~/.stub-harness/auth.json"]!) as? [String: Any])
        XCTAssertEqual(Set(stubDoc.keys), ["stub-credential", "unrelated"])
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], secondAuth)
    }

    func testConcurrentPiUpdateBetweenPreparationAndWriteSurvives() throws {
        // H4 reproduction: Pi adds an unrelated provider after Switcheroo's
        // preparation read but before the Pi write. The locked write re-reads
        // the document, so the fresh provider survives.
        let (harness, _, secondId, _, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.files[piAuthPath] = Data(#"{"opencode-go": {"type": "api_key"}}"#.utf8)
        harness.fileIO.onWriteToPath = { writtenPath in
            if writtenPath == self.activeAuthPath {
                harness.fileIO.files[self.piAuthPath] = Data(#"{"opencode-go": {"type": "api_key"}, "fresh-provider": {"new": true}}"#.utf8)
            }
        }

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex", "opencode-go", "fresh-provider"])
        let fresh = try XCTUnwrap(piDoc["fresh-provider"] as? [String: Any])
        XCTAssertEqual(fresh["new"] as? Bool, true)
    }

    func testCodexReplacementAndPiSectionUpsertSemanticsRemainDistinct() throws {
        // A replace-mode target overwrites the whole file; a section target
        // preserves unrelated entries. Both run through the same orchestration.
        let replaceStub = StubAuthTargetAdapter(
            id: "replace-target",
            defaultDestinationAuthFilePath: "~/.replace-target/auth.json",
            writeMode: .replaceWithSource
        )
        let (harness, _, secondId, _, secondAuth) = try makeTwoAccountHarness(
            authTargetAdapters: [replaceStub]
        )
        harness.fileIO.files["~/.replace-target/auth.json"] = Data("stale unrelated content".utf8)

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        XCTAssertEqual(harness.fileIO.files["~/.replace-target/auth.json"], secondAuth)
        // The pi file was untouched: no section adapter is registered here.
        XCTAssertNil(harness.fileIO.files[piAuthPath])
    }

    // MARK: - Safe failure behavior

    func testConversionFailureChangesNothing() throws {
        let failing = StubAuthTargetAdapter()
        failing.conversionError = AuthTargetSyncError.unsupportedSource(targetId: "stub-target", reason: "test failure")
        let (harness, _, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [failing]
        )
        let piFileBefore = Data(#"{"opencode-go": {"type": "api_key"}}"#.utf8)
        harness.fileIO.files[piAuthPath] = piFileBefore

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.unsupportedSource = error else {
                return XCTFail("Expected unsupportedSource, got \(error)")
            }
        }

        // Conversion fails during preparation, before any publication: nothing changed.
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)
        XCTAssertEqual(harness.fileIO.files[piAuthPath], piFileBefore)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertFalse(harness.fileIO.itemExists(path: "/tmp/switcheroo-tests/state/transaction.json"))
    }

    func testSwitchRollsBackWhenTargetWriteFails() throws {
        let (harness, firstId, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.failWritePaths.insert(piAuthPath)

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.destinationWriteFailed(let targetId, let path, _) = error else {
                return XCTFail("Expected destinationWriteFailed, got \(error)")
            }
            XCTAssertEqual(targetId, "pi")
            XCTAssertEqual(path, piAuthPath)
        }

        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        XCTAssertEqual(savedConfig.providers.first?.activeAccountId, firstId)
        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, firstId)
    }

    func testSwitchRollsBackWhenDestinationIsMalformed() throws {
        let (harness, firstId, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.files[piAuthPath] = Data("this is not json".utf8)

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.malformedDestination(let targetId, _) = error else {
                return XCTFail("Expected malformedDestination, got \(error)")
            }
            XCTAssertEqual(targetId, "pi")
        }

        // The malformed destination is detected before any write: nothing changed.
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)
        XCTAssertEqual(harness.fileIO.files[piAuthPath], Data("this is not json".utf8))
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, firstId)
    }

    func testSwitchFailureDiagnosticsNeverContainCredentials() throws {
        let secretAccess = "SECRET-ACCESS-JWT-123"
        let secretRefresh = "SECRET-REFRESH-456"
        let (harness, _, secondId, _, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.secureStore.items["codex:acc-second"] = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_200, "x": secretAccess]),
            refreshToken: secretRefresh
        )
        harness.fileIO.files[piAuthPath] = Data("garbage".utf8)

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            let message = error.localizedDescription
            XCTAssertFalse(message.contains(secretAccess))
            XCTAssertFalse(message.contains(secretRefresh))
        }
    }

    func testSwitchRollsBackAndSurfacesRollbackFailureWhenActiveFileWasModified() throws {
        let (harness, firstId, secondId, _, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        // The active file changes between our write and the rollback: another
        // process overwrote it, so the rollback must not clobber that write.
        harness.fileIO.failWritePaths.insert(piAuthPath)
        harness.fileIO.onWriteToPath = { path in
            if path == self.activeAuthPath {
                harness.fileIO.files[self.activeAuthPath] = Data("concurrent-overwrite".utf8)
            }
        }

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        XCTAssertEqual(harness.fileIO.files[activeAuthPath], Data("concurrent-overwrite".utf8))
        // Config was never persisted (the switch aborted before the config commit).
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, firstId)
        // The unrecoverable rollback leaves the journal for startup recovery.
        XCTAssertTrue(harness.fileIO.itemExists(path: "/tmp/switcheroo-tests/state/transaction.json"))
    }

    // MARK: - Activation writes (add/import with set-active)

    func testFinalizeAddAccountWithSetActiveSynchronizesTargets() throws {
        let harness = try EngineHarness(authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-work"]]),
            refreshToken: "refresh-work",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-work"]])
        )

        let pending = try harness.engine.startAddAccount(name: "Work")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        try harness.engine.finalizeAddAccount(pending, setActive: true)

        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex"])
        let codex = try XCTUnwrap(piDoc["openai-codex"] as? [String: Any])
        XCTAssertEqual(codex["refresh"] as? String, "refresh-work")
        XCTAssertEqual(codex["accountId"] as? String, "acct-work")
    }

    func testFinalizeAddAccountWithSetActiveRollsBackOnTargetFailure() throws {
        let harness = try EngineHarness(authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData()
        harness.fileIO.failWritePaths.insert(piAuthPath)

        let pending = try harness.engine.startAddAccount(name: "Work")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        XCTAssertThrowsError(try harness.engine.finalizeAddAccount(pending, setActive: true)) { error in
            guard case AuthTargetSyncError.destinationWriteFailed = error else {
                return XCTFail("Expected destinationWriteFailed, got \(error)")
            }
        }

        // Keychain snapshot removed, config restored, no active auth file left behind.
        XCTAssertTrue(harness.secureStore.items.isEmpty)
        XCTAssertNil(harness.fileIO.files["~/.codex/auth.json"])
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        XCTAssertTrue(savedConfig.providers.isEmpty)
        XCTAssertNil(savedConfig.defaultProviderId)
        XCTAssertTrue(harness.configStore.config.providers.isEmpty)
    }

    // MARK: - Fixture

    private func makeTwoAccountHarness(
        authTargetAdapters: [any AuthTargetAdapter]
    ) throws -> (harness: EngineHarness, firstId: String, secondId: String, firstAuth: Data, secondAuth: Data) {
        let firstAuth = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            refreshToken: "refresh-first",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            tokensAccountId: "acct-first"
        )
        let secondAuth = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_200, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-second"]]),
            refreshToken: "refresh-second",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-second"]]),
            tokensAccountId: "acct-second"
        )
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(
                    id: "codex",
                    activeAccountId: first.id,
                    accounts: [first, second],
                    activeAuthFilePathOverride: activeAuthPath
                ),
            ]
        )
        let harness = try EngineHarness(config: config, authTargetAdapters: authTargetAdapters)
        harness.secureStore.items["codex:\(first.id)"] = firstAuth
        harness.secureStore.items["codex:\(second.id)"] = secondAuth
        harness.fileIO.files[activeAuthPath] = firstAuth
        return (harness, first.id, second.id, firstAuth, secondAuth)
    }
}
