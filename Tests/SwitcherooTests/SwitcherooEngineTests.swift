import XCTest
@testable import SwitcherooCore

final class SwitcherooEngineTests: XCTestCase {
    func testListAccountsSortsAndResolvesDefaultProvider() throws {
        let alpha = makeAccount(id: "alpha", name: "alpha")
        let bravo = makeAccount(id: "bravo", name: "Bravo")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [bravo, alpha]),
            ]
        )
        let harness = try EngineHarness(config: config)

        let accounts = try harness.engine.listAccounts()

        XCTAssertEqual(accounts.map(\.name), ["alpha", "Bravo"])
    }

    func testListAccountsUsesOnlyProviderWhenNoDefaultConfigured() throws {
        let config = SwitcherooConfig(
            providers: [
                makeProviderState(id: "codex", accounts: [makeAccount(id: "acc-1", name: "One")]),
            ]
        )
        let harness = try EngineHarness(config: config)

        let accounts = try harness.engine.listAccounts()

        XCTAssertEqual(accounts.map(\.name), ["One"])
    }

    func testStartFinalizeAddAccountStoresAuthAndSetsActive() throws {
        let harness = try EngineHarness()
        let authData = try makeAuthData(email: "work@example.com", accountId: "acct-1")

        let pending = try harness.engine.startAddAccount(name: "Work")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        try harness.engine.finalizeAddAccount(pending, setActive: true)

        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        let account = try XCTUnwrap(provider.accounts.first)

        XCTAssertEqual(savedConfig.defaultProviderId, "codex")
        XCTAssertEqual(provider.activeAccountId, account.id)
        XCTAssertEqual(account.name, "Work")
        XCTAssertEqual(harness.secureStore.items["codex:\(pending.accountId)"], authData)
        XCTAssertEqual(harness.fileIO.writes.map(\.path), ["~/.codex/auth.json"])
        XCTAssertEqual(harness.fileIO.writes.first?.permissions, 0o600)
        XCTAssertEqual(harness.paths.removedPaths, [pending.providerHomePath])
        XCTAssertEqual(harness.provider.prepareLoginCalls.count, 1)
        XCTAssertEqual(harness.provider.launchLoginInteractiveCalls.count, 1)
    }

    func testFinalizeAddAccountWithoutSetActiveLeavesActiveUnset() throws {
        let harness = try EngineHarness()
        let authData = try makeAuthData(accountId: "acct-2")

        let pending = try harness.engine.startAddAccount(name: "Side")
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        try harness.engine.finalizeAddAccount(pending, setActive: false)

        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        let account = try XCTUnwrap(provider.accounts.first)

        XCTAssertNil(provider.activeAccountId)
        XCTAssertEqual(account.name, "Side")
        XCTAssertTrue(harness.fileIO.writes.isEmpty)
    }

    func testFinalizeAddAccountThrowsWhenAuthFileIsMissing() throws {
        let harness = try EngineHarness()
        let pending = try harness.engine.startAddAccount(name: "Missing")

        XCTAssertThrowsError(try harness.engine.finalizeAddAccount(pending, setActive: false)) { error in
            guard let switcherooError = error as? SwitcherooError else {
                XCTFail("Expected missing auth file error")
                return
            }
            switch switcherooError {
            case .missingAuthFile(let path):
                XCTAssertEqual(path, pending.expectedAuthFilePath)
            default:
                XCTFail("Expected missing auth file error")
            }
        }
    }

    func testImportCurrentAccountWithDerivedNamePrefersEmail() throws {
        let activePath = "/tmp/active/auth.json"
        let authData = try makeAuthData(email: "dev@example.com", accountId: "acct-3")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        harness.fileIO.files[activePath] = authData

        let account = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)

        XCTAssertEqual(account.name, "dev@example.com")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, account.id)
        XCTAssertEqual(provider.accounts.count, 1)
        XCTAssertEqual(harness.secureStore.items["codex:\(account.id)"], authData)
    }

    func testImportCurrentAccountWithExplicitNameStoresThatName() throws {
        let activePath = "/tmp/active/auth.json"
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        harness.fileIO.files[activePath] = try makeAuthData(email: "named@example.com", accountId: "acct-3")

        let account = try harness.engine.importCurrentAccount(name: "Personal", setActive: true)

        XCTAssertEqual(account.name, "Personal")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, account.id)
        XCTAssertEqual(provider.accounts.first?.name, "Personal")
    }

    func testImportCurrentAccountWithDerivedNameFallsBackToAccountIdThenImportedPrefix() throws {
        let activePath = "/tmp/active/auth.json"
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)

        let accountIdData = try makeAuthData(accountId: "acct-4")
        harness.fileIO.files[activePath] = accountIdData
        let accountById = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)

        XCTAssertEqual(accountById.name, "acct-4")

        harness.fileIO.files[activePath] = try makeAuthData()
        let imported = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: false)

        XCTAssertTrue(imported.name.hasPrefix("Imported "))
    }

    func testSwitchDeleteRenameAndSyncWorkflow() throws {
        let activePath = "/tmp/active/auth.json"
        let firstAuth = try makeAuthData(email: "first@example.com", accountId: "acct-5")
        let secondAuth = try makeAuthData(email: "second@example.com", accountId: "acct-6")
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(
                    id: "codex",
                    activeAccountId: first.id,
                    accounts: [first, second],
                    activeAuthFilePathOverride: activePath
                ),
            ]
        )
        let harness = try EngineHarness(config: config)
        harness.secureStore.items["codex:\(first.id)"] = firstAuth
        harness.secureStore.items["codex:\(second.id)"] = secondAuth

        try harness.engine.switchToAccount(accountIdOrName: "acc-sec")
        var savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        var provider = try XCTUnwrap(savedConfig.providers.first)
        let active = try XCTUnwrap(provider.accounts.first(where: { $0.id == second.id }))

        XCTAssertEqual(provider.activeAccountId, second.id)
        XCTAssertEqual(active.name, "Second")
        XCTAssertNotNil(active.lastUsedAt)
        XCTAssertEqual(harness.fileIO.writes.last?.path, activePath)
        XCTAssertEqual(harness.fileIO.writes.last?.data, secondAuth)

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()
        XCTAssertTrue(synced)
        XCTAssertEqual(harness.secureStore.items["codex:\(second.id)"], secondAuth)

        try harness.engine.renameAccount(accountId: second.id, newName: "Renamed")
        savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.first(where: { $0.id == second.id })?.name, "Renamed")

        try harness.engine.deleteAccount(accountIdOrName: "Renamed")
        savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.map(\.id), [first.id])
        XCTAssertNil(provider.activeAccountId)
        XCTAssertEqual(harness.secureStore.deletedKeys.last, "codex:\(second.id)")
    }

    func testSwitchToAccountResolvesByExactIdAndName() throws {
        let activePath = "/tmp/active/auth.json"
        let first = makeAccount(id: "acc-first", name: "First")
        let second = makeAccount(id: "acc-second", name: "Second")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(
                    id: "codex",
                    activeAccountId: first.id,
                    accounts: [first, second],
                    activeAuthFilePathOverride: activePath
                ),
            ]
        )
        let harness = try EngineHarness(config: config)
        harness.secureStore.items["codex:\(first.id)"] = try makeAuthData(email: "first@example.com", accountId: "acct-5")
        harness.secureStore.items["codex:\(second.id)"] = try makeAuthData(email: "second@example.com", accountId: "acct-6")

        try harness.engine.switchToAccount(accountIdOrName: second.id)
        var savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        var provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, second.id)

        try harness.engine.switchToAccount(accountIdOrName: "First")
        savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, first.id)
    }

    func testAccessTokenExpiryAndMetadataSkipMissingItems() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000_123)
        let activePath = "/tmp/active/auth.json"
        let account = makeAccount(id: "acc-meta", name: "Meta")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(
                    id: "codex",
                    activeAccountId: account.id,
                    accounts: [account],
                    activeAuthFilePathOverride: activePath
                ),
            ]
        )
        let harness = try EngineHarness(config: config)
        let authData = try makeAuthData(email: "meta@example.com", accountId: "acct-meta", accessTokenExpiry: expiry)
        harness.secureStore.items["codex:\(account.id)"] = authData

        let expiryById = try harness.engine.accessTokenExpiryByAccountId()
        let metadataById = try harness.engine.metadataByAccountId()

        if let actualExpiry = expiryById[account.id]?.timeIntervalSince1970 {
            XCTAssertEqual(actualExpiry, expiry.timeIntervalSince1970, accuracy: 0.5)
        } else {
            XCTFail("Missing expiry for account")
        }
        XCTAssertEqual(metadataById[account.id]?.email, "meta@example.com")
        if let actualExpiry = metadataById[account.id]?.accessTokenExpiry?.timeIntervalSince1970 {
            XCTAssertEqual(actualExpiry, expiry.timeIntervalSince1970, accuracy: 0.5)
        } else {
            XCTFail("Missing metadata expiry for account")
        }
    }

    func testSyncActiveSnapshotReturnsFalseWithoutActiveAccount() throws {
        let harness = try EngineHarness()

        XCTAssertFalse(try harness.engine.syncActiveAccountSnapshotIfNeeded())
    }

    func testListAccountsThrowsWhenNoProviderCanBeResolved() throws {
        let engine = try SwitcherooEngine(
            configStore: InMemoryConfigStore(),
            secureStore: InMemorySecureStore(),
            fileIO: InMemoryFileIO(),
            paths: InMemoryPaths(),
            providers: []
        )

        XCTAssertThrowsError(try engine.listAccounts()) { error in
            guard let switcherooError = error as? SwitcherooError else {
                XCTFail("Expected provider not found error")
                return
            }
            switch switcherooError {
            case .providerNotFound(let providerId):
                XCTAssertEqual(providerId, "(none)")
            default:
                XCTFail("Expected provider not found error")
            }
        }
    }

    func testSwitchToUnknownAccountThrows() throws {
        let account = makeAccount(id: "acc-1", name: "One")
        let harness = try EngineHarness(
            config: SwitcherooConfig(
                defaultProviderId: "codex",
                providers: [
                    makeProviderState(id: "codex", accounts: [account]),
                ]
            )
        )

        XCTAssertThrowsError(try harness.engine.switchToAccount(accountIdOrName: "missing")) { error in
            guard let switcherooError = error as? SwitcherooError else {
                XCTFail("Expected account not found error")
                return
            }
            switch switcherooError {
            case .accountNotFound:
                return
            default:
                XCTFail("Expected account not found error")
            }
        }
    }
}
