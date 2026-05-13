import XCTest
import SwitcherooCore
import SwitcherooPresentation

final class SwitcherooAppTests: XCTestCase {
    func testRefreshPopulatesStatusAndMetadata() throws {
        let activePath = "/tmp/active/auth.json"
        let account = makeAccount(id: "acc-1", name: "Alpha")
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
        let authData = try makeAuthData(email: "alpha@example.com", accountId: "acct-alpha", accessTokenExpiry: Date(timeIntervalSince1970: 1_700_000_200))
        harness.secureStore.items["codex:\(account.id)"] = authData

        let app = harness.makeApp()
        app.refresh()

        XCTAssertEqual(app.state.accounts.map(\.name), ["Alpha"])
        XCTAssertEqual(app.state.activeAccountId, account.id)
        XCTAssertEqual(app.state.statusText, "Alpha")
        XCTAssertEqual(app.state.accountMetadataById[account.id]?.email, "alpha@example.com")
        if let expiry = app.state.accessTokenExpiryByAccountId[account.id]?.timeIntervalSince1970 {
            XCTAssertEqual(expiry, 1_700_000_200, accuracy: 0.5)
        } else {
            XCTFail("Missing expiry for active account")
        }
    }

    func testAddFinalizeSwitchDeleteAndSyncFlow() throws {
        let harness = try EngineHarness()
        let app = harness.makeApp()
        let authData = try makeAuthData(email: "work@example.com", accountId: "acct-2")

        app.startAddAccount(name: "Work")
        let pending = try XCTUnwrap(app.state.pendingLogin)
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        app.finalizePendingIfReady(setActive: true)

        let added = try XCTUnwrap(app.state.accounts.first)
        XCTAssertEqual(added.name, "Work")
        XCTAssertEqual(app.state.activeAccountId, added.id)
        XCTAssertNil(app.state.pendingLogin)
        XCTAssertEqual(harness.fileIO.writes.last?.path, "~/.codex/auth.json")

        app.switchToAccount(idOrName: added.id.prefix(6).description)
        XCTAssertEqual(app.state.activeAccountId, added.id)
        XCTAssertEqual(harness.fileIO.writes.last?.path, "~/.codex/auth.json")

        app.renameAccount(accountId: added.id, newName: "Renamed")
        XCTAssertEqual(app.state.accounts.first?.name, "Renamed")

        app.syncActiveSnapshot()
        XCTAssertEqual(harness.secureStore.items["codex:\(added.id)"], authData)

        app.deleteAccount(idOrName: added.id)
        XCTAssertTrue(app.state.accounts.isEmpty)
        XCTAssertNil(app.state.activeAccountId)
        XCTAssertEqual(harness.secureStore.deletedKeys.last, "codex:\(added.id)")
    }

    func testImportCurrentAccountWithDerivedNameSetsActiveOnlyForFirstAccount() throws {
        let activePath = "/tmp/current/auth.json"
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        let emailData = try makeAuthData(email: "current@example.com", accountId: "acct-3")
        harness.fileIO.files[activePath] = emailData

        let first = try XCTUnwrap(harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true).account)
        XCTAssertEqual(first.name, "current@example.com")

        harness.fileIO.files[activePath] = try makeAuthData(accountId: "acct-4")
        let second = try XCTUnwrap(harness.engine.importCurrentAccountWithDerivedName(setActiveIfFirst: true).account)
        XCTAssertEqual(second.name, "acct-4")

        let app = harness.makeApp()
        app.refresh()

        XCTAssertEqual(app.state.accounts.map(\.name), ["acct-4", "current@example.com"])
        XCTAssertEqual(app.state.activeAccountId, first.id)
    }

    func testImportCurrentAccountWithExplicitNameUsesThatName() throws {
        let activePath = "/tmp/named/auth.json"
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", activeAuthFilePathOverride: activePath),
            ]
        )
        let harness = try EngineHarness(config: config)
        harness.fileIO.files[activePath] = try makeAuthData(email: "named@example.com", accountId: "acct-5")

        let app = harness.makeApp()
        app.importCurrentAccount(name: "Personal")

        XCTAssertEqual(app.state.accounts.map(\.name), ["Personal"])
        XCTAssertNil(app.state.activeAccountId)
        XCTAssertEqual(app.state.statusText, "No active account")
    }

    func testAutoSyncDoesNotRequireReloginWhenThereIsNoActiveAccount() throws {
        let account = makeAccount(id: "acc-1", name: "Configured")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [account]),
            ]
        )
        let harness = try EngineHarness(config: config)
        let app = harness.makeApp()
        app.refresh()

        let decision = app.autoSyncDecision(now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(decision, .disabled(requiresRelogin: false))
        XCTAssertFalse(app.state.requiresRelogin)
    }

    func testFinalizePendingWithDerivedNameActivatesNewAccountWhenNoneIsActive() throws {
        let existing = makeAccount(id: "acc-existing", name: "Existing")
        let config = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                makeProviderState(id: "codex", accounts: [existing]),
            ]
        )
        let harness = try EngineHarness(config: config)
        let app = harness.makeApp()
        let authData = try makeAuthData(email: "new@example.com", accountId: "acct-new")

        app.startAddAccount(name: "New account")
        let pending = try XCTUnwrap(app.state.pendingLogin)
        harness.fileIO.files[pending.expectedAuthFilePath] = authData

        let result = try XCTUnwrap(app.finalizePendingIfReady(setActiveIfFirst: true))

        XCTAssertEqual(result.disposition, .created)
        let added = try XCTUnwrap(result.account)
        XCTAssertEqual(app.state.activeAccountId, added.id)
        XCTAssertEqual(harness.fileIO.writes.last?.path, "~/.codex/auth.json")
        XCTAssertEqual(harness.fileIO.writes.last?.data, authData)
    }

    func testSelectProviderUpdatesSelectionAndStillRefreshesState() throws {
        let harness = try EngineHarness()
        let app = harness.makeApp(providerDescriptors: [
            ProviderDescriptor(id: "codex", displayName: "Codex"),
            ProviderDescriptor(id: "other", displayName: "Other"),
        ])

        app.selectProvider("codex")

        XCTAssertEqual(app.state.selectedProviderId, "codex")
        XCTAssertEqual(app.state.providers.map(\.id), ["codex", "other"])
    }

    func testShouldShowProviderUIWhenMultipleProvidersExist() throws {
        let harness = try EngineHarness()
        let app = harness.makeApp(providerDescriptors: [
            ProviderDescriptor(id: "codex", displayName: "Codex"),
            ProviderDescriptor(id: "other", displayName: "Other"),
        ])

        XCTAssertTrue(app.shouldShowProviderUI())
    }
}
