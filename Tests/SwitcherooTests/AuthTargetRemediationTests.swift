import XCTest
@testable import SwitcherooCLI
@testable import SwitcherooCore
import SwitcherooCodexProvider
import SwitcherooPiAdapter
import SwitcherooPresentation

/// Regression coverage for the independent review findings H1-H4, M1-M7.
/// Each test reproduces the reported failure mode and asserts the corrected
/// behavior.
final class AuthTargetRemediationTests: XCTestCase {
    private let activeAuthPath = "/tmp/active/auth.json"
    private let piAuthPath = "~/.pi/agent/auth.json"
    private let journalPath = "/tmp/switcheroo-tests/state/transaction.json"
    private let lockPath = "/tmp/switcheroo-tests/state/switch.lock"

    // MARK: - H1: the engine must never silently run without auth targets

    func testEngineRejectsEmptyTargetSet() {
        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: InMemoryConfigStore(),
            secureStore: InMemorySecureStore(),
            fileIO: InMemoryFileIO(),
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: []
        )) { error in
            guard case SwitcherooError.noAuthTargetsConfigured = error else {
                return XCTFail("Expected noAuthTargetsConfigured, got \(error)")
            }
        }
    }

    // MARK: - H2: crash recovery via the transaction journal

    func testStartupReconcilesUncommittedTransactionByRestoringEverything() throws {
        let firstAuth = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            refreshToken: "refresh-first",
            tokensAccountId: "acct-first"
        )
        let secondAuth = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_200, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-second"]]),
            refreshToken: "refresh-second",
            tokensAccountId: "acct-second"
        )
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let previousConfig = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [makeProviderState(
                id: "codex",
                activeAccountId: first.id,
                accounts: [first, second],
                activeAuthFilePathOverride: activeAuthPath
            )]
        )

        let configStore = InMemoryConfigStore(config: previousConfig)
        let secureStore = InMemorySecureStore()
        let fileIO = InMemoryFileIO()
        // Crash state: journal exists, config not committed, Codex already
        // published the new account, Pi never published.
        fileIO.files[activeAuthPath] = secondAuth
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-1",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [
                TransactionJournal.Target(id: "codex", path: activeAuthPath, previous: firstAuth, expected: secondAuth),
                TransactionJournal.Target(id: "pi", path: piAuthPath, previous: nil),
            ],
            keychainChanges: []
        ))

        _ = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json"), PiAuthTargetAdapter()]
        )

        XCTAssertEqual(fileIO.files[activeAuthPath], firstAuth)
        XCTAssertNil(fileIO.files[piAuthPath])
        XCTAssertEqual(configStore.config.providers.first?.activeAccountId, first.id)
        XCTAssertFalse(fileIO.itemExists(path: journalPath))
    }

    func testStartupResolvesJournaledQuarantineBeforeRestoringNilPreimage() throws {
        let previousConfig = SwitcherooConfig()
        let published = Data("published".utf8)
        let quarantinePath = "\(activeAuthPath).switcheroo-quarantine.crash-3.0"
        let fileIO = InMemoryFileIO()
        fileIO.files[quarantinePath] = published
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-3",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [
                TransactionJournal.Target(
                    id: "codex",
                    path: activeAuthPath,
                    previous: nil,
                    expected: published,
                    quarantinePath: quarantinePath
                ),
            ],
            keychainChanges: []
        ))

        _ = try SwitcherooEngine(
            configStore: InMemoryConfigStore(config: previousConfig),
            secureStore: InMemorySecureStore(),
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: activeAuthPath)]
        )

        XCTAssertNil(fileIO.files[activeAuthPath])
        XCTAssertNil(fileIO.files[quarantinePath])
        XCTAssertFalse(fileIO.itemExists(path: journalPath))
    }

    func testStartupRestoresUnexpectedQuarantineAndRetainsJournal() throws {
        let previousConfig = SwitcherooConfig()
        let published = Data("published".utf8)
        let concurrent = Data("concurrent".utf8)
        let quarantinePath = "\(activeAuthPath).switcheroo-quarantine.crash-4.0"
        let fileIO = InMemoryFileIO()
        fileIO.files[quarantinePath] = concurrent
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-4",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [
                TransactionJournal.Target(
                    id: "codex",
                    path: activeAuthPath,
                    previous: nil,
                    expected: published,
                    quarantinePath: quarantinePath
                ),
            ],
            keychainChanges: []
        ))

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: InMemoryConfigStore(config: previousConfig),
            secureStore: InMemorySecureStore(),
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: activeAuthPath)]
        )) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        XCTAssertEqual(fileIO.files[activeAuthPath], concurrent)
        XCTAssertNil(fileIO.files[quarantinePath])
        XCTAssertTrue(fileIO.itemExists(path: journalPath))
        let journal = try JSONDecoder().decode(TransactionJournal.self, from: try XCTUnwrap(fileIO.files[journalPath]))
        XCTAssertNil(journal.targets.first?.quarantinePath)
    }

    func testRollbackJournalsQuarantineBeforeRemovingNilPreimage() throws {
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [makeProviderState(
                id: "codex",
                activeAccountId: first.id,
                accounts: [first, second],
                activeAuthFilePathOverride: activeAuthPath
            )]
        )
        let stub = StubAuthTargetAdapter(
            defaultDestinationAuthFilePath: "~/.stub-target/auth.json",
            writeMode: .replaceWithSource
        )
        let harness = try EngineHarness(
            config: config,
            includeCodexTarget: false,
            authTargetAdapters: [stub, CodexAuthTargetAdapter(defaultAuthFilePath: activeAuthPath)]
        )
        let firstAuth = try makeCodexAuthData(refreshToken: "first")
        let secondAuth = try makeCodexAuthData(refreshToken: "second")
        harness.secureStore.items["codex:\(first.id)"] = firstAuth
        harness.secureStore.items["codex:\(second.id)"] = secondAuth
        harness.fileIO.files[activeAuthPath] = firstAuth
        harness.fileIO.failWritePaths.insert(activeAuthPath)

        var observedJournaledQuarantine = false
        harness.fileIO.onAtomicRemoveMove = { path, _ in
            guard path == "~/.stub-target/auth.json",
                  let data = harness.fileIO.files[self.journalPath],
                  let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data) else {
                return
            }
            observedJournaledQuarantine = journal.targets.contains {
                $0.path == path && $0.quarantinePath != nil
            }
        }

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: second.id))
        XCTAssertTrue(observedJournaledQuarantine)
        XCTAssertFalse(harness.fileIO.itemExists(path: "~/.stub-target/auth.json"))
    }

    func testStartupReconcilesCommittedTransactionByCompletingIt() throws {
        let firstAuth = try makeCodexAuthData(refreshToken: "refresh-first")
        let secondAuth = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_200, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-second"]]),
            refreshToken: "refresh-second",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-second"]]),
            tokensAccountId: "acct-second"
        )
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let committedConfig = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [makeProviderState(
                id: "codex",
                activeAccountId: second.id,
                accounts: [first, second],
                activeAuthFilePathOverride: activeAuthPath
            )]
        )
        let configStore = InMemoryConfigStore(config: committedConfig)
        let secureStore = InMemorySecureStore()
        let fileIO = InMemoryFileIO()
        fileIO.files[activeAuthPath] = secondAuth
        let committedPi = Data(#"{"openai-codex": {"type": "oauth"}}"#.utf8)
        fileIO.files[piAuthPath] = committedPi
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-2",
            createdAt: Date(),
            configCommitted: true,
            committedConfig: committedConfig,
            previousConfig: committedConfig,
            targets: [
                TransactionJournal.Target(id: "codex", path: activeAuthPath, previous: firstAuth, expected: secondAuth),
                TransactionJournal.Target(id: "pi", path: piAuthPath, previous: nil, expected: committedPi),
            ],
            keychainChanges: []
        ))

        _ = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json"), PiAuthTargetAdapter()]
        )

        XCTAssertEqual(fileIO.files[activeAuthPath], secondAuth)
        XCTAssertEqual(configStore.config.providers.first?.activeAccountId, second.id)
        XCTAssertFalse(fileIO.itemExists(path: journalPath))
    }

    func testStartupDoesNotOverwritePiChangesAfterInterruptedPublication() throws {
        let firstAuth = try makeCodexAuthData(refreshToken: "first")
        let publishedAuth = try makeCodexAuthData(refreshToken: "published")
        let previousConfig = SwitcherooConfig()
        let configStore = InMemoryConfigStore(config: previousConfig)
        let secureStore = InMemorySecureStore()
        let fileIO = InMemoryFileIO()
        let concurrentPi = Data(#"{"openai-codex": {"refresh": "concurrent"}}"#.utf8)
        fileIO.files[piAuthPath] = concurrentPi
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-pi-race",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [
                TransactionJournal.Target(id: "pi", path: piAuthPath, previous: firstAuth, expected: publishedAuth),
            ],
            keychainChanges: []
        ))

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [PiAuthTargetAdapter()]
        ))

        XCTAssertEqual(fileIO.files[piAuthPath], concurrentPi)
        XCTAssertTrue(fileIO.itemExists(path: journalPath))
    }

    func testStartupFailsClosedWhenPublicationBytesAreMissing() throws {
        let previousAuth = try makeCodexAuthData(refreshToken: "previous")
        let publishedAuth = try makeCodexAuthData(refreshToken: "published")
        let previousConfig = SwitcherooConfig()
        let fileIO = InMemoryFileIO()
        fileIO.files[activeAuthPath] = publishedAuth
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-before-journal-callback",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [
                TransactionJournal.Target(
                    id: "codex",
                    path: activeAuthPath,
                    previous: previousAuth,
                    publicationStarted: true
                ),
            ],
            keychainChanges: []
        ))

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: InMemoryConfigStore(config: previousConfig),
            secureStore: InMemorySecureStore(),
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: activeAuthPath)]
        )) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        XCTAssertEqual(fileIO.files[activeAuthPath], publishedAuth)
        XCTAssertTrue(fileIO.itemExists(path: journalPath))
    }

    func testStartupFailsClosedForJournalWithoutPublicationMarker() throws {
        let previousAuth = try makeCodexAuthData(refreshToken: "previous")
        let publishedAuth = try makeCodexAuthData(refreshToken: "published")
        let previousConfig = SwitcherooConfig()
        let fileIO = InMemoryFileIO()
        fileIO.files[activeAuthPath] = publishedAuth

        var journalObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TransactionJournal(
                txid: "legacy-journal",
                createdAt: Date(),
                configCommitted: false,
                previousConfig: previousConfig,
                targets: [TransactionJournal.Target(id: "codex", path: activeAuthPath, previous: previousAuth, expected: publishedAuth)],
                keychainChanges: []
            ))
        ) as? [String: Any])
        var targets = try XCTUnwrap(journalObject["targets"] as? [[String: Any]])
        targets[0].removeValue(forKey: "publicationStarted")
        journalObject["targets"] = targets
        fileIO.files[journalPath] = try JSONSerialization.data(withJSONObject: journalObject)

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: InMemoryConfigStore(config: previousConfig),
            secureStore: InMemorySecureStore(),
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: activeAuthPath)]
        )) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        XCTAssertEqual(fileIO.files[activeAuthPath], publishedAuth)
        XCTAssertTrue(fileIO.itemExists(path: journalPath))
    }

    func testCommittedJournalCleanupFailureDoesNotTriggerRollback() throws {
        let (harness, _, secondId, _, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.failRemovePaths.insert(journalPath)

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, secondId)
        let journalData = try XCTUnwrap(harness.fileIO.files[journalPath])
        XCTAssertTrue(try JSONDecoder().decode(TransactionJournal.self, from: journalData).configCommitted)
    }

    func testCommitMarkerDurabilityFailureLeavesJournalUncommittedWhenRollbackIsIncomplete() throws {
        let (harness, firstId, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        let concurrentPi = Data(#"{"openai-codex":{"type":"oauth","access":"concurrent"}}"#.utf8)
        harness.fileIO.onWriteToPath = { path in
            guard path == self.journalPath,
                  let data = harness.fileIO.files[path],
                  let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data),
                  journal.configCommitted else {
                return
            }
            harness.fileIO.files[self.piAuthPath] = concurrentPi
            harness.fileIO.failAfterWriteOncePaths.insert(path)
        }

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        let journalData = try XCTUnwrap(harness.fileIO.files[journalPath])
        XCTAssertFalse(try JSONDecoder().decode(TransactionJournal.self, from: journalData).configCommitted)
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)
        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, firstId)
    }

    func testJournalResetFailureStopsRollbackAndStartupRejectsMixedCommittedState() throws {
        let (harness, _, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.onWriteToPath = { path in
            guard path == self.journalPath,
                  let data = harness.fileIO.files[path],
                  let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data),
                  journal.configCommitted else {
                return
            }
            harness.fileIO.files[self.activeAuthPath] = firstAuth
            harness.fileIO.failWritePaths.insert(path)
            harness.fileIO.failAfterWriteOncePaths.insert(path)
        }

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }

        let journalData = try XCTUnwrap(harness.fileIO.files[journalPath])
        let journal = try JSONDecoder().decode(TransactionJournal.self, from: journalData)
        XCTAssertTrue(journal.configCommitted)
        XCTAssertEqual(journal.committedConfig, harness.configStore.config)
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: harness.configStore,
            secureStore: harness.secureStore,
            fileIO: harness.fileIO,
            paths: harness.paths,
            providers: [harness.provider],
            authTargetAdapters: harness.authTargetAdapters
        )) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }
        XCTAssertTrue(harness.fileIO.itemExists(path: journalPath))
    }

    func testStartupReconcileRollsBackJournaledKeychainChanges() throws {
        let previousStored = try makeCodexAuthData(refreshToken: "old-refresh")
        let newStored = try makeCodexAuthData(refreshToken: "new-refresh")
        let previousConfig = SwitcherooConfig()
        let configStore = InMemoryConfigStore(config: previousConfig)
        let secureStore = InMemorySecureStore()
        let key = "codex:acc-1"
        secureStore.items[key] = newStored
        let fileIO = InMemoryFileIO()
        fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "crash-3",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: previousConfig,
            targets: [],
            keychainChanges: [
                TransactionJournal.KeychainChange(op: "store", key: key, previous: previousStored),
            ]
        ))

        _ = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json"), PiAuthTargetAdapter()]
        )

        XCTAssertEqual(secureStore.items[key], previousStored)
        XCTAssertFalse(fileIO.itemExists(path: journalPath))
    }

    func testStartupFailsWhenJournalIsUnreadable() throws {
        let fileIO = InMemoryFileIO()
        fileIO.files[journalPath] = Data("corrupt journal".utf8)

        XCTAssertThrowsError(try SwitcherooEngine(
            configStore: InMemoryConfigStore(),
            secureStore: InMemorySecureStore(),
            fileIO: fileIO,
            paths: InMemoryPaths(),
            providers: [StubProvider()],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json"), PiAuthTargetAdapter()]
        )) { error in
            guard case AuthTargetSyncError.rollbackIncomplete = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
        }
    }

    func testNewTransactionReconcilesLeftoverJournalFirst() throws {
        // A failed switch left an uncommitted journal; the next switch must
        // reconcile it (restoring the old active account) before publishing.
        let (harness, firstId, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.files[journalPath] = try JSONEncoder().encode(TransactionJournal(
            txid: "leftover",
            createdAt: Date(),
            configCommitted: false,
            previousConfig: harness.configStore.config,
            targets: [TransactionJournal.Target(id: "codex", path: activeAuthPath, previous: firstAuth, expected: firstAuth)],
            keychainChanges: []
        ))

        try harness.engine.switchToAccount(accountIdOrName: secondId)

        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, secondId)
        XCTAssertFalse(harness.fileIO.itemExists(path: journalPath))
        XCTAssertEqual(harness.fileIO.files[activeAuthPath], harness.secureStore.items["codex:acc-second"])
    }

    // MARK: - H3: transaction serialization across engines

    func testConcurrentSwitchesEndOnOneCompleteTransaction() throws {
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
            providers: [makeProviderState(
                id: "codex",
                activeAccountId: first.id,
                accounts: [first, second],
                activeAuthFilePathOverride: activeAuthPath
            )]
        )
        let configStore = InMemoryConfigStore(config: config)
        let secureStore = InMemorySecureStore()
        let fileIO = InMemoryFileIO()
        let paths = InMemoryPaths()
        secureStore.items["codex:\(first.id)"] = firstAuth
        secureStore.items["codex:\(second.id)"] = secondAuth
        fileIO.files[activeAuthPath] = firstAuth

        let makeEngine = {
            try SwitcherooEngine(
                configStore: configStore,
                secureStore: secureStore,
                fileIO: fileIO,
                paths: paths,
                providers: [StubProvider()],
                authTargetAdapters: [
                    CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json"),
                    PiAuthTargetAdapter(),
                ]
            )
        }
        let engineA = try makeEngine()
        let engineB = try makeEngine()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "switch-race", attributes: .concurrent)
        var errorsA: [Error] = []
        var errorsB: [Error] = []
        group.enter()
        queue.async {
            do { try engineA.switchToAccount(accountIdOrName: "acc-second") }
            catch { errorsA.append(error) }
            group.leave()
        }
        group.enter()
        queue.async {
            do { try engineB.switchToAccount(accountIdOrName: "acc-first") }
            catch { errorsB.append(error) }
            group.leave()
        }
        group.wait()
        XCTAssertTrue(errorsA.isEmpty, "engineA failed: \(errorsA.map(\.localizedDescription))")
        XCTAssertTrue(errorsB.isEmpty, "engineB failed: \(errorsB.map(\.localizedDescription))")

        // Serialized transactions: config, Codex file, and Pi credential must
        // all name the same account (never a mixture).
        let activeId = try XCTUnwrap(configStore.config.providers.first?.activeAccountId)
        let codexBytes = try XCTUnwrap(fileIO.files[activeAuthPath])
        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: fileIO.files[piAuthPath]!) as? [String: Any])
        let piCredential = try XCTUnwrap(piDoc["openai-codex"] as? [String: Any])

        switch activeId {
        case first.id:
            XCTAssertEqual(codexBytes, firstAuth)
            XCTAssertEqual(piCredential["accountId"] as? String, "acct-first")
        case second.id:
            XCTAssertEqual(codexBytes, secondAuth)
            XCTAssertEqual(piCredential["accountId"] as? String, "acct-second")
        default:
            XCTFail("Active account id \(activeId) does not match either account")
        }
        XCTAssertFalse(fileIO.itemExists(path: journalPath))
    }

    // MARK: - M3: CLI must surface switch failures

    func testCLISwitchFailurePrintsErrorAndExitsNonZero() {
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [makeAccount(id: "acc-1", name: "One")]))
        app.switchError = AuthTargetSyncError.malformedDestination(targetId: "pi", path: piAuthPath)
        var output: [String] = []
        var errors: [String] = []

        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { errors.append($0) })

        XCTAssertEqual(cli.run(arguments: ["switch", "acc-1"]), 1)
        XCTAssertEqual(app.switchCalls, ["acc-1"])
        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(errors, ["switcheroo: Could not sync pi: auth file at \(piAuthPath) is not a valid JSON object."])
    }

    // MARK: - M4: Keychain and config rollback failures are first-class

    func testActivationAbortsWhenKeychainPreImageCannotBeLoaded() throws {
        let existing = makeAccount(id: "acc-existing", name: "Existing", identityKey: "account_id:acct-existing")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [makeProviderState(id: "codex", accounts: [existing])]
        )
        let harness = try EngineHarness(config: config, authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-existing"]]),
            refreshToken: "refresh-existing",
            tokensAccountId: "acct-existing"
        )
        let stored = try makeCodexAuthData(refreshToken: "stale-refresh")
        harness.secureStore.items["codex:acc-existing"] = stored
        harness.secureStore.failLoadKeys.insert("codex:acc-existing")

        let pending = try harness.engine.startAddAccount(name: "Existing")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        XCTAssertThrowsError(try harness.engine.finalizeAddAccount(pending, setActive: true))

        // Nothing was mutated: the failure happened before the transaction.
        XCTAssertEqual(harness.secureStore.items["codex:acc-existing"], stored)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertFalse(harness.fileIO.itemExists(path: journalPath))
    }

    func testKeychainRollbackFailureSurfacesAsRollbackIncomplete() throws {
        // Activation path: the keychain change is applied inside the transaction;
        // a failing keychain rollback must surface as rollbackIncomplete.
        let harness = try EngineHarness(authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData()
        harness.fileIO.failWritePaths.insert(piAuthPath)

        let pending = try harness.engine.startAddAccount(name: "Work")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData
        harness.secureStore.failDeleteKeys.insert("codex:\(pending.accountId)")

        XCTAssertThrowsError(try harness.engine.finalizeAddAccount(pending, setActive: true)) { error in
            guard case AuthTargetSyncError.rollbackIncomplete(let message) = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
            XCTAssertTrue(message.contains("Keychain item 'codex:\(pending.accountId)' could not be restored"))
        }

        // The journal survives so startup reconciliation can retry.
        XCTAssertTrue(harness.fileIO.itemExists(path: journalPath))
        XCTAssertFalse(harness.fileIO.itemExists(path: "~/.codex/auth.json"))
    }

    func testConfigRollbackFailureSurfacesAsRollbackIncomplete() throws {
        let (harness, firstId, secondId, firstAuth, _) = try makeTwoAccountHarness(
            authTargetAdapters: [PiAuthTargetAdapter()]
        )
        harness.fileIO.failWritePaths.insert(piAuthPath)
        harness.configStore.failSaves = true

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: secondId)) { error in
            guard case AuthTargetSyncError.rollbackIncomplete(let message) = error else {
                return XCTFail("Expected rollbackIncomplete, got \(error)")
            }
            XCTAssertTrue(message.contains("config could not be restored"))
        }

        XCTAssertEqual(harness.fileIO.files[activeAuthPath], firstAuth)
        XCTAssertTrue(harness.fileIO.itemExists(path: journalPath))
        _ = firstId
    }

    // MARK: - M5: colliding destination paths are rejected before any write

    func testCollidingResolvedDestinationsAreRejectedBeforeAnyWrite() throws {
        let previous = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", "~/.codex", 1)
        defer {
            if let previous {
                setenv("PI_CODING_AGENT_DIR", previous, 1)
            } else {
                unsetenv("PI_CODING_AGENT_DIR")
            }
        }

        // No path override: both adapters resolve to ~/.codex/auth.json.
        let authData = try makeCodexAuthData()
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [makeProviderState(id: "codex", activeAccountId: first.id, accounts: [first, second])]
        )
        let harness = try EngineHarness(config: config, authTargetAdapters: [PiAuthTargetAdapter()])
        harness.secureStore.items["codex:\(first.id)"] = authData
        harness.secureStore.items["codex:\(second.id)"] = authData
        harness.fileIO.files["~/.codex/auth.json"] = authData

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: second.id)) { error in
            guard case AuthTargetSyncError.destinationCollision(let path, let targets) = error else {
                return XCTFail("Expected destinationCollision, got \(error)")
            }
            XCTAssertEqual(path, "~/.codex/auth.json")
            XCTAssertTrue(targets.contains("codex"))
            XCTAssertTrue(targets.contains("pi"))
        }

        // Nothing was written or persisted.
        XCTAssertEqual(harness.fileIO.files["~/.codex/auth.json"], authData)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
    }

    // MARK: - M6: activating an import synchronizes Pi without rewriting Codex

    func testFirstImportActivationSynchronizesPiWithoutRewritingCodex() throws {
        let harness = try EngineHarness(authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            refreshToken: "refresh-first",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            tokensAccountId: "acct-first"
        )
        harness.fileIO.files["~/.codex/auth.json"] = authData
        harness.fileIO.files[piAuthPath] = Data(#"{"opencode-go": {"type": "api_key"}}"#.utf8)

        let result = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)
        let account = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(harness.configStore.config.providers.first?.activeAccountId, account.id)

        // Pi received the credential; the unrelated provider survived.
        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex", "opencode-go"])
        let codex = try XCTUnwrap(piDoc["openai-codex"] as? [String: Any])
        XCTAssertEqual(codex["accountId"] as? String, "acct-first")

        // The Codex file was not rewritten: it already held exactly these bytes.
        XCTAssertTrue(harness.fileIO.publishedWrites.allSatisfy { $0.path != "~/.codex/auth.json" })
    }

    func testImportCurrentAccountWithSetActiveSynchronizesPi() throws {
        let harness = try EngineHarness(authTargetAdapters: [PiAuthTargetAdapter()])
        let authData = try makeCodexAuthData(
            accessToken: makeJWT(payload: ["exp": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            refreshToken: "refresh-first",
            idToken: makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-first"]]),
            tokensAccountId: "acct-first"
        )
        harness.fileIO.files["~/.codex/auth.json"] = authData

        let result = try harness.engine.importCurrentAccount(name: "Imported", setActive: true)

        XCTAssertEqual(result.disposition, .created)
        let piDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.fileIO.files[piAuthPath]!) as? [String: Any])
        XCTAssertEqual(Set(piDoc.keys), ["openai-codex"])
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
