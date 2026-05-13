import XCTest
@testable import SwitcherooMenuBar
import SwitcherooCore
import SwitcherooPresentation

@MainActor
final class AppModelTests: XCTestCase {
    func testInitWithInjectedAppSeedsState() {
        let app = MockSwitcherooApp(
            state: SwitcherooAppState(
                accounts: [makeAccount(id: "acc-1", name: "Seed")],
                activeAccountId: "acc-1"
            )
        )

        let model = AppModel(app: app)

        XCTAssertEqual(model.state.accounts.map(\.name), ["Seed"])
        XCTAssertEqual(model.state.activeAccountId, "acc-1")
        XCTAssertEqual(app.refreshCalls, 0)
    }

    func testRefreshUsesSnapshotFromApp() {
        let app = MockSwitcherooApp(
            state: SwitcherooAppState(
                accounts: [makeAccount(id: "acc-1", name: "Before")],
                activeAccountId: "acc-1"
            )
        )
        let model = AppModel(app: app)
        app.nextSnapshot = SwitcherooAppState(
            accounts: [makeAccount(id: "acc-2", name: "After")],
            activeAccountId: "acc-2"
        )

        model.refresh()

        XCTAssertEqual(app.refreshCalls, 1)
        XCTAssertEqual(model.state.accounts.map(\.name), ["After"])
        XCTAssertEqual(model.state.activeAccountId, "acc-2")
    }

    func testStartAddAccountPublishesPendingLogin() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-1",
            accountName: "New account",
            providerHomePath: "/tmp/pending-1",
            expectedAuthFilePath: "/tmp/pending-1/auth.json"
        )
        let app = MockSwitcherooApp()
        app.nextPendingLogin = pending
        let model = AppModel(app: app)

        model.startAddAccount()

        XCTAssertEqual(app.startAddAccountCalls, 1)
        XCTAssertEqual(model.state.pendingLogin?.accountId, "pending-1")
        XCTAssertEqual(model.state.pendingHint, "Complete login, then Switcheroo will import it.")
    }

    func testFinalizePendingUsesDerivedFlowAndBeginsRenameDraft() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-2",
            accountName: "Work",
            providerHomePath: "/tmp/pending-2",
            expectedAuthFilePath: "/tmp/pending-2/auth.json"
        )
        let account = makeAccount(id: "acc-2", name: "Derived Name")
        let app = MockSwitcherooApp(state: SwitcherooAppState(pendingLogin: pending, pendingHint: "pending"))
        app.nextFinalizedAccount = account
        let model = AppModel(app: app)

        model.finalizePendingIfReady(setActive: false)

        XCTAssertEqual(app.finalizeDerivedCalls, [true])
        XCTAssertEqual(app.finalizeSetActiveCalls, [])
        XCTAssertEqual(model.renameDraftAccountId, account.id)
        XCTAssertEqual(model.renameDraftPlaceholder, "Derived Name")
        XCTAssertEqual(model.renameDraftText, "")
        XCTAssertEqual(model.statusMessage, "Added account.")
        XCTAssertNil(model.state.pendingLogin)
    }

    func testFinalizePendingDuplicateDoesNotBeginRenameDraft() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-dup",
            accountName: "Work",
            providerHomePath: "/tmp/pending-dup",
            expectedAuthFilePath: "/tmp/pending-dup/auth.json"
        )
        let account = makeAccount(id: "acc-existing", name: "Existing")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account], pendingLogin: pending, pendingHint: "pending"))
        app.nextFinalizedAccount = account
        app.nextFinalizedDisposition = .updatedExisting
        let model = AppModel(app: app)

        model.finalizePendingIfReady(setActive: false)

        XCTAssertEqual(app.finalizeDerivedCalls, [true])
        XCTAssertEqual(app.finalizeSetActiveCalls, [])
        XCTAssertNil(model.renameDraftAccountId)
        XCTAssertEqual(model.statusMessage, "Refreshed Existing.")
        XCTAssertNil(model.state.pendingLogin)
    }

    func testFinalizePendingFallsBackToExplicitSetActivePath() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-3",
            accountName: "Work",
            providerHomePath: "/tmp/pending-3",
            expectedAuthFilePath: "/tmp/pending-3/auth.json"
        )
        let app = MockSwitcherooApp(state: SwitcherooAppState(pendingLogin: pending, pendingHint: "pending"))
        app.forceDerivedFinalizeToReturnNil = true
        let model = AppModel(app: app)

        model.finalizePendingIfReady(setActive: true)

        XCTAssertEqual(app.finalizeDerivedCalls, [true])
        XCTAssertEqual(app.finalizeSetActiveCalls, [true])
        XCTAssertNil(model.renameDraftAccountId)
        XCTAssertNil(model.statusMessage)
        XCTAssertNil(model.state.pendingLogin)
    }

    func testImportCurrentAccountBeginsRenameDraft() {
        let account = makeAccount(id: "acc-4", name: "Imported Name")
        let app = MockSwitcherooApp()
        app.nextImportedAccount = account
        let model = AppModel(app: app)

        model.importCurrentAccount()

        XCTAssertEqual(app.importCurrentAccountDerivedCalls, [true])
        XCTAssertEqual(model.renameDraftAccountId, account.id)
        XCTAssertEqual(model.renameDraftPlaceholder, "Imported Name")
        XCTAssertEqual(model.renameDraftText, "")
        XCTAssertEqual(model.statusMessage, "Imported account.")
        XCTAssertEqual(model.state.accounts.map(\.name), ["Imported Name"])
    }

    func testImportCurrentDuplicateDoesNotBeginRenameDraft() {
        let account = makeAccount(id: "acc-4", name: "Existing")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account]))
        app.nextImportedAccount = account
        app.nextImportedDisposition = .updatedExisting
        let model = AppModel(app: app)

        model.importCurrentAccount()

        XCTAssertEqual(app.importCurrentAccountDerivedCalls, [true])
        XCTAssertNil(model.renameDraftAccountId)
        XCTAssertEqual(model.statusMessage, "Refreshed Existing.")
        XCTAssertEqual(model.state.accounts.map(\.name), ["Existing"])
    }

    func testStatusMessageAutoDismissesAfterConfiguredDelay() async throws {
        let account = makeAccount(id: "acc-4", name: "Existing")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account]))
        app.nextImportedAccount = account
        app.nextImportedDisposition = .updatedExisting
        let model = AppModel(app: app, statusMessageAutoDismissNanoseconds: 1_000_000)

        model.importCurrentAccount()

        XCTAssertEqual(model.statusMessage, "Refreshed Existing.")

        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(model.statusMessage)
    }

    func testNewStatusMessageCancelsPreviousAutoDismiss() async throws {
        let first = makeAccount(id: "acc-4", name: "First")
        let second = makeAccount(id: "acc-5", name: "Second")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [first, second]))
        app.nextImportedAccount = first
        app.nextImportedDisposition = .updatedExisting
        let model = AppModel(app: app, statusMessageAutoDismissNanoseconds: 20_000_000)

        model.importCurrentAccount()
        XCTAssertEqual(model.statusMessage, "Refreshed First.")

        try await Task.sleep(nanoseconds: 5_000_000)

        app.nextImportedAccount = second
        model.importCurrentAccount()
        XCTAssertEqual(model.statusMessage, "Refreshed Second.")

        try await Task.sleep(nanoseconds: 18_000_000)

        XCTAssertEqual(model.statusMessage, "Refreshed Second.")

        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertNil(model.statusMessage)
    }

    func testImportCurrentFailureClearsStatusAndPublishesErrorState() {
        let app = MockSwitcherooApp()
        app.forceDerivedImportToReturnNil = true
        app.state.errorMessage = "Missing auth file"
        let model = AppModel(app: app)
        model.statusMessage = "Previous status"

        model.importCurrentAccount()

        XCTAssertEqual(app.importCurrentAccountDerivedCalls, [true])
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.state.errorMessage, "Missing auth file")
        XCTAssertNil(model.renameDraftAccountId)
    }

    func testSaveRenameDraftUsesTrimmedTextAndPlaceholderFallback() {
        let account = makeAccount(id: "acc-5", name: "Current")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account]))
        let model = AppModel(app: app)

        model.startRenameDraft(accountId: account.id, currentName: account.name)
        model.renameDraftText = "  Updated Name  "
        model.saveRenameDraft()

        XCTAssertEqual(app.renameCalls.count, 1)
        XCTAssertEqual(app.renameCalls[0].accountId, account.id)
        XCTAssertEqual(app.renameCalls[0].newName, "Updated Name")
        XCTAssertNil(model.renameDraftAccountId)
        XCTAssertEqual(model.state.accounts.first?.name, "Updated Name")

        model.startRenameDraft(accountId: account.id, currentName: "Fallback")
        model.renameDraftText = "   "
        model.saveRenameDraft()

        XCTAssertEqual(app.renameCalls.count, 2)
        XCTAssertEqual(app.renameCalls[1].accountId, account.id)
        XCTAssertEqual(app.renameCalls[1].newName, "Fallback")
        XCTAssertNil(model.renameDraftAccountId)
    }

    func testCancelRenameDraftClearsState() {
        let app = MockSwitcherooApp()
        let model = AppModel(app: app)

        model.startRenameDraft(accountId: "acc-6", currentName: "Current")
        model.cancelRenameDraft()

        XCTAssertNil(model.renameDraftAccountId)
        XCTAssertEqual(model.renameDraftText, "")
        XCTAssertEqual(model.renameDraftPlaceholder, "")
    }

    func testSwitchDeleteAndSyncForwardToApp() {
        let account = makeAccount(id: "acc-7", name: "Account")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account]))
        let model = AppModel(app: app)

        model.switchToAccount(account.id)
        model.deleteAccount(account.id)
        model.syncActiveSnapshot()

        XCTAssertEqual(app.switchCalls, [account.id])
        XCTAssertEqual(app.deleteCalls, [account.id])
        XCTAssertEqual(app.syncCalls, 1)
        XCTAssertTrue(model.state.accounts.isEmpty)
    }
}
