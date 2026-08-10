import XCTest
@testable import SwitcherooCodexProvider
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
        XCTAssertEqual(account.identityKey, "account_id:acct-1|email:work@example.com")

        XCTAssertEqual(harness.secureStore.items["codex:\(pending.accountId)"], authData)
        XCTAssertEqual(harness.fileIO.publishedWrites.map(\.path), ["~/.codex/auth.json"])
        XCTAssertEqual(harness.fileIO.publishedWrites.first?.permissions, 0o600)
        XCTAssertFalse(harness.fileIO.itemExists(path: "/tmp/switcheroo-tests/state/transaction.json"))
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
        XCTAssertEqual(account.identityKey, "account_id:acct-2")
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

        let result = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)
        let account = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(account.name, "dev@example.com")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, account.id)
        XCTAssertEqual(provider.accounts.count, 1)
        XCTAssertEqual(provider.accounts.first?.identityKey, "account_id:acct-3|email:dev@example.com")
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(account.id)"), authData)
    }

    func testImportCurrentAccountDoesNotOverwriteExistingWhenAccountIdMatchesButEmailDiffers() throws {
        let activePath = "/tmp/active/auth.json"
        let existing = makeAccount(id: "acc-existing", name: "Work", identityKey: "account_id:acct-dup")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [existing], activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        let oldData = try makeAuthData(email: "old@example.com", accountId: "acct-dup")
        let newData = try makeAuthData(email: "new@example.com", accountId: "acct-dup")
        try harness.secureStore.store(oldData, key: "codex:\(existing.id)")
        harness.fileIO.files[activePath] = newData

        let result = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)
        let imported = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertNotEqual(imported.id, existing.id)
        XCTAssertEqual(imported.name, "new@example.com")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(Set(provider.accounts.map(\.id)), Set([existing.id, imported.id]))
        XCTAssertEqual(provider.activeAccountId, imported.id)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(existing.id)"), oldData)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(imported.id)"), newData)
    }

    func testImportCurrentAccountWithDuplicateExplicitNamePreservesExistingNameAndActiveWhenNotRequested() throws {
        let activePath = "/tmp/active/auth.json"
        let active = makeAccount(id: "acc-active", name: "Active", identityKey: "account_id:acct-active")
        let duplicate = makeAccount(id: "acc-duplicate", name: "Custom Name", identityKey: "account_id:acct-duplicate")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(
                    id: "codex",
                    activeAccountId: active.id,
                    accounts: [active, duplicate],
                    activeAuthFilePathOverride: activePath
                ),
            ]
        )
        let harness = try EngineHarness(config: config)
        let activeAuth = try makeAuthData(email: "active@example.com", accountId: "acct-active")
        let storedDuplicateAuth = try makeAuthData(email: "old@example.com", accountId: "acct-duplicate")
        let duplicateAuth = try makeAuthData(email: "duplicate@example.com", accountId: "acct-duplicate")
        try harness.secureStore.store(activeAuth, key: "codex:\(active.id)")
        try harness.secureStore.store(storedDuplicateAuth, key: "codex:\(duplicate.id)")
        harness.fileIO.files[activePath] = duplicateAuth

        let result = try harness.engine.importCurrentAccount(name: "Typed Name", setActive: false)
        let imported = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertNotEqual(imported.id, duplicate.id)
        XCTAssertEqual(imported.name, "Typed Name")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, active.id)
        XCTAssertEqual(Set(provider.accounts.map(\.id)), Set([active.id, duplicate.id, imported.id]))
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(active.id)"), activeAuth)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(duplicate.id)"), storedDuplicateAuth)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(imported.id)"), duplicateAuth)
        XCTAssertTrue(harness.fileIO.writes.isEmpty)
    }

    func testFinalizeAddAccountDoesNotOverwriteExistingWhenAccountIdMatchesButEmailDiffers() throws {
        let existing = makeAccount(id: "acc-existing", name: "Existing")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [existing]),
            ]
        )
        let harness = try EngineHarness(config: config)
        let oldData = try makeAuthData(email: "old@example.com", accountId: "acct-existing")
        let newData = try makeAuthData(email: "new@example.com", accountId: "acct-existing")
        try harness.secureStore.store(oldData, key: "codex:\(existing.id)")

        let pending = try harness.engine.startAddAccount(name: "New Duplicate")
        harness.fileIO.files[pending.expectedAuthFilePath] = newData

        let result = try harness.engine.finalizeAddAccount(pending, setActive: true)
        let created = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(created.id, pending.accountId)
        XCTAssertEqual(created.name, "New Duplicate")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, pending.accountId)
        XCTAssertEqual(Set(provider.accounts.map(\.id)), Set([existing.id, pending.accountId]))

        XCTAssertEqual(harness.secureStore.items["codex:\(existing.id)"], oldData)
        XCTAssertEqual(harness.secureStore.items["codex:\(pending.accountId)"], newData)
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.path, "~/.codex/auth.json")
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.data, newData)
        XCTAssertEqual(harness.paths.removedPaths, [pending.providerHomePath])
    }

    func testFinalizeAddAccountDuplicateWithoutSetActivePreservesCurrentActiveAccount() throws {
        let active = makeAccount(id: "acc-active", name: "Active", identityKey: "account_id:acct-active")
        let duplicate = makeAccount(id: "acc-duplicate", name: "Duplicate", identityKey: "account_id:acct-duplicate")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAccountId: active.id, accounts: [active, duplicate]),
            ]
        )
        let harness = try EngineHarness(config: config)
        let activeAuth = try makeAuthData(email: "active@example.com", accountId: "acct-active")
        let storedDuplicateAuth = try makeAuthData(email: "old@example.com", accountId: "acct-duplicate")
        let duplicateAuth = try makeAuthData(email: "duplicate@example.com", accountId: "acct-duplicate")
        try harness.secureStore.store(activeAuth, key: "codex:\(active.id)")
        try harness.secureStore.store(storedDuplicateAuth, key: "codex:\(duplicate.id)")

        let pending = try harness.engine.startAddAccount(name: "Duplicate Login")
        harness.fileIO.files[pending.expectedAuthFilePath] = duplicateAuth

        let result = try harness.engine.finalizeAddAccount(pending, setActive: false)
        let created = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(created.id, pending.accountId)
        XCTAssertEqual(created.name, "Duplicate Login")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, active.id)
        XCTAssertEqual(Set(provider.accounts.map(\.id)), Set([active.id, duplicate.id, pending.accountId]))
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(active.id)"), activeAuth)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(duplicate.id)"), storedDuplicateAuth)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(pending.accountId)"), duplicateAuth)
        XCTAssertTrue(harness.fileIO.writes.isEmpty)
        XCTAssertEqual(harness.paths.removedPaths, [pending.providerHomePath])
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

        let result = try harness.engine.importCurrentAccount(name: "Personal", setActive: true)
        let account = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(account.name, "Personal")
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, account.id)
        XCTAssertEqual(provider.accounts.first?.name, "Personal")
        XCTAssertEqual(provider.accounts.first?.identityKey, "account_id:acct-3|email:named@example.com")
    }

    func testImportCurrentAccountCreatesSeparateAccountWhenAccountIdDiffersEvenIfEmailMatches() throws {
        let activePath = "/tmp/active/auth.json"
        let existing = makeAccount(id: "acc-existing", name: "Existing", identityKey: "account_id:acct-existing")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [existing], activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        try harness.secureStore.store(try makeAuthData(email: "same@example.com", accountId: "acct-existing"), key: "codex:\(existing.id)")
        let newAuth = try makeAuthData(email: "same@example.com", accountId: "acct-new")
        harness.fileIO.files[activePath] = newAuth

        let result = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)
        let newAccount = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertNotEqual(newAccount.id, existing.id)
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(Set(provider.accounts.map(\.id)), Set([existing.id, newAccount.id]))
        XCTAssertEqual(provider.activeAccountId, newAccount.id)
        XCTAssertEqual(provider.accounts.first(where: { $0.id == newAccount.id })?.identityKey, "account_id:acct-new|email:same@example.com")
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(newAccount.id)"), newAuth)
    }

    func testImportCurrentAccountUpdatesDuplicateByEmailFallbackWhenAccountIdIsMissing() throws {
        let activePath = "/tmp/active/auth.json"
        let existing = makeAccount(id: "acc-email", name: "Email Account", identityKey: "email:person@example.com")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [existing], activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        let oldData = try makeAuthData(email: "person@example.com")
        let newData = try makeAuthData(email: " PERSON@EXAMPLE.COM ")
        try harness.secureStore.store(oldData, key: "codex:\(existing.id)")
        harness.fileIO.files[activePath] = newData

        let result = try harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true)

        XCTAssertEqual(result.disposition, .updatedExisting)
        XCTAssertEqual(result.account?.id, existing.id)
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.map(\.id), [existing.id])
        XCTAssertEqual(provider.activeAccountId, existing.id)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(existing.id)"), newData)
    }

    func testImportCurrentAccountCreatesAccountForUnparseableNonEmptyAuth() throws {
        let activePath = "/tmp/active/auth.json"
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        let authData = Data("not-json-but-non-empty".utf8)
        harness.fileIO.files[activePath] = authData

        let result = try harness.engine.importCurrentAccount(name: "Manual", setActive: false)
        let account = try XCTUnwrap(result.account)

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(account.name, "Manual")
        XCTAssertNil(account.identityKey)
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.map(\.id), [account.id])
        XCTAssertNil(provider.accounts.first?.identityKey)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(account.id)"), authData)
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
        let accountById = try XCTUnwrap(harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true).account)

        XCTAssertEqual(accountById.name, "acct-4")

        harness.fileIO.files[activePath] = try makeAuthData()
        let imported = try XCTUnwrap(harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: false).account)

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
        try harness.secureStore.store(firstAuth, key: "codex:\(first.id)")
        try harness.secureStore.store(secondAuth, key: "codex:\(second.id)")

        try harness.engine.switchToAccount(accountIdOrName: "acc-sec")
        var savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        var provider = try XCTUnwrap(savedConfig.providers.first)
        let active = try XCTUnwrap(provider.accounts.first(where: { $0.id == second.id }))

        XCTAssertEqual(provider.activeAccountId, second.id)
        XCTAssertEqual(active.name, "Second")
        XCTAssertNotNil(active.lastUsedAt)
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.path, activePath)
        XCTAssertEqual(harness.fileIO.publishedWrites.last?.data, secondAuth)

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()
        XCTAssertTrue(synced)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(second.id)"), secondAuth)

        try harness.engine.renameAccount(accountId: second.id, newName: "Renamed")
        savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.first(where: { $0.id == second.id })?.name, "Renamed")

        try harness.engine.deleteAccount(accountIdOrName: "Renamed")
        savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.accounts.map(\.id), [first.id])
        XCTAssertNil(provider.activeAccountId)
        XCTAssertEqual(harness.secureStore.recordedDeletedKeys.last, "codex:\(second.id)")
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
        try harness.secureStore.store(try makeAuthData(email: "first@example.com", accountId: "acct-5"), key: "codex:\(first.id)")
        try harness.secureStore.store(try makeAuthData(email: "second@example.com", accountId: "acct-6"), key: "codex:\(second.id)")

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
        try harness.secureStore.store(authData, key: "codex:\(account.id)")

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

    func testSyncActiveSnapshotUpdatesMatchedNonActiveAccountAndCorrectsActiveId() throws {
        let activePath = "/tmp/active/auth.json"
        let first = makeAccount(id: "acc-first", name: "First", identityKey: "account_id:acct-first")
        let second = makeAccount(id: "acc-second", name: "Second", identityKey: "account_id:acct-second")
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
        let firstAuth = try makeAuthData(email: "first@example.com", accountId: "acct-first")
        let secondAuth = try makeAuthData(email: "second@example.com", accountId: "acct-second")
        try harness.secureStore.store(firstAuth, key: "codex:\(first.id)")
        try harness.secureStore.store(try makeAuthData(email: "old-second@example.com", accountId: "acct-second"), key: "codex:\(second.id)")
        harness.fileIO.files[activePath] = secondAuth

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()

        XCTAssertFalse(synced)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(first.id)"), firstAuth)
        XCTAssertNotEqual(try? harness.secureStore.load(key: "codex:\(second.id)"), secondAuth)
    }

    func testSyncActiveSnapshotUpdatesMatchedAccountEvenWhenActiveIdIsStale() throws {
        let activePath = "/tmp/active/auth.json"
        let first = makeAccount(id: "acc-first", name: "First", identityKey: "account_id:acct-first|email:first@example.com")
        let second = makeAccount(id: "acc-second", name: "Second", identityKey: "account_id:acct-second|email:second@example.com")
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
        let firstAuth = try makeAuthData(email: "first@example.com", accountId: "acct-first")
        let oldSecondAuth = try makeAuthData(email: "second@example.com", accountId: "acct-second", accessTokenExpiry: Date(timeIntervalSince1970: 1_700_000_000))
        let refreshedSecondAuth = try makeAuthData(email: "second@example.com", accountId: "acct-second", accessTokenExpiry: Date(timeIntervalSince1970: 1_700_010_000))
        try harness.secureStore.store(firstAuth, key: "codex:\(first.id)")
        try harness.secureStore.store(oldSecondAuth, key: "codex:\(second.id)")
        harness.fileIO.files[activePath] = refreshedSecondAuth

        let result = try harness.engine.syncActiveAccountSnapshot()

        XCTAssertEqual(result.disposition, .updatedExisting)
        XCTAssertEqual(result.account?.id, second.id)
        let savedConfig = try XCTUnwrap(harness.configStore.savedConfigs.last)
        let provider = try XCTUnwrap(savedConfig.providers.first)
        XCTAssertEqual(provider.activeAccountId, second.id)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(first.id)"), firstAuth)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(second.id)"), refreshedSecondAuth)
    }

    func testSyncActiveSnapshotSkipsUnknownCurrentAuthIdentity() throws {
        let activePath = "/tmp/active/auth.json"
        let account = makeAccount(id: "acc-active", name: "Active", identityKey: "account_id:acct-active")
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
        let storedAuth = try makeAuthData(email: "active@example.com", accountId: "acct-active")
        let unknownAuth = try makeAuthData(email: "unknown@example.com", accountId: "acct-unknown")
        try harness.secureStore.store(storedAuth, key: "codex:\(account.id)")
        harness.fileIO.files[activePath] = unknownAuth

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()

        XCTAssertFalse(synced)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(account.id)"), storedAuth)
        XCTAssertEqual(harness.secureStore.recordedStoredKeys, ["codex:\(account.id)"], "sync must not write to the secure store")
    }

    func testSyncActiveSnapshotSkipsUnparseableCurrentAuthWithoutOverwritingActiveSnapshot() throws {
        let activePath = "/tmp/active/auth.json"
        let account = makeAccount(id: "acc-active", name: "Active", identityKey: "account_id:acct-active")
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
        let storedAuth = try makeAuthData(email: "active@example.com", accountId: "acct-active")
        try harness.secureStore.store(storedAuth, key: "codex:\(account.id)")
        harness.fileIO.files[activePath] = Data("not-json".utf8)

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()

        XCTAssertFalse(synced)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(account.id)"), storedAuth)
        XCTAssertEqual(harness.secureStore.recordedStoredKeys, ["codex:\(account.id)"], "sync must not write to the secure store")
    }

    func testSyncActiveSnapshotReturnsFalseWhenAccountIdMatchesButEmailDiffers() throws {
        let activePath = "/tmp/active/auth.json"
        let account = makeAccount(id: "acc-active", name: "Active")
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
        let oldAuth = try makeAuthData(email: "old@example.com", accountId: "acct-active")
        let currentAuth = try makeAuthData(email: "current@example.com", accountId: "acct-active")
        try harness.secureStore.store(oldAuth, key: "codex:\(account.id)")
        harness.fileIO.files[activePath] = currentAuth

        let synced = try harness.engine.syncActiveAccountSnapshotIfNeeded()

        XCTAssertFalse(synced)
        XCTAssertTrue(harness.configStore.savedConfigs.isEmpty)
        XCTAssertEqual(try? harness.secureStore.load(key: "codex:\(account.id)"), oldAuth)
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
            providers: [],
            authTargetAdapters: [CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")]
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
