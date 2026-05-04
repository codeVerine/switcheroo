import XCTest
@testable import SwitcherooMenuBar
import SwitcherooCore
import SwitcherooPresentation

final class StatusViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyStateDerivesStaticTextAndFlags() {
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(),
            renameDraftAccountId: nil,
            now: now
        )

        XCTAssertEqual(viewModel.title, "Switcheroo")
        XCTAssertEqual(viewModel.versionText, "v1.0")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showHeaderActions)
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(viewModel.emptyState.title, "No accounts configured")
        XCTAssertEqual(viewModel.emptyState.message, "Sync an existing session or log in\nvia Terminal to get started.")
        XCTAssertEqual(viewModel.emptyState.primaryActionTitle, "Sync current account")
        XCTAssertEqual(viewModel.emptyState.secondaryActionTitle, "Add new account")
        XCTAssertEqual(viewModel.footerText, "No active session")
        XCTAssertEqual(viewModel.accountListMaxHeight, 12)
    }

    func testAccountMappingReflectsActiveRenameMetadataAndExpiry() {
        let active = makeAccount(id: "acc-1", name: "Primary")
        let backup = makeAccount(id: "acc-2", name: "Backup")
        let state = SwitcherooAppState(
            errorMessage: "Sync failed",
            accounts: [active, backup],
            activeAccountId: active.id,
            accessTokenExpiryByAccountId: [
                active.id: now.addingTimeInterval(7_200),
                backup.id: now.addingTimeInterval(300),
            ],
            accountMetadataById: [
                active.id: SwitcherooAccountMetadata(email: "primary@example.com"),
                backup.id: SwitcherooAccountMetadata(email: "backup@example.com"),
            ]
        )

        let viewModel = StatusViewModel(state: state, renameDraftAccountId: backup.id, now: now)

        XCTAssertEqual(viewModel.errorMessage, "Sync failed")
        XCTAssertTrue(viewModel.showHeaderActions)
        XCTAssertFalse(viewModel.isEmpty)
        XCTAssertEqual(viewModel.footerText, "2 accounts")
        XCTAssertEqual(viewModel.accounts.count, 2)

        let activeView = viewModel.accounts[0]
        XCTAssertEqual(activeView.id, active.id)
        XCTAssertEqual(activeView.name, "Primary")
        XCTAssertEqual(activeView.email, "primary@example.com")
        XCTAssertTrue(activeView.isActive)
        XCTAssertFalse(activeView.isRenaming)
        XCTAssertEqual(activeView.activeLabel, "ACTIVE")
        XCTAssertFalse(activeView.showSwitchAction)
        XCTAssertEqual(activeView.expiry?.text, "2h left")
        XCTAssertEqual(activeView.expiry?.kind, .neutral)

        let backupView = viewModel.accounts[1]
        XCTAssertEqual(backupView.id, backup.id)
        XCTAssertEqual(backupView.email, "backup@example.com")
        XCTAssertFalse(backupView.isActive)
        XCTAssertTrue(backupView.isRenaming)
        XCTAssertNil(backupView.activeLabel)
        XCTAssertTrue(backupView.showSwitchAction)
        XCTAssertEqual(backupView.expiry?.text, "5m left")
        XCTAssertEqual(backupView.expiry?.kind, .warning)
    }

    func testAccountListHeightCapsAtFourRows() {
        let empty = StatusViewModel(state: SwitcherooAppState(), renameDraftAccountId: nil, now: now)
        XCTAssertEqual(empty.accountListMaxHeight, 12)

        let oneAccount = StatusViewModel(
            state: SwitcherooAppState(accounts: [makeAccount(name: "One")]),
            renameDraftAccountId: nil,
            now: now
        )
        XCTAssertEqual(oneAccount.accountListMaxHeight, 67)

        let fourAccounts = StatusViewModel(
            state: SwitcherooAppState(accounts: [
                makeAccount(name: "One"),
                makeAccount(name: "Two"),
                makeAccount(name: "Three"),
                makeAccount(name: "Four"),
            ]),
            renameDraftAccountId: nil,
            now: now
        )
        XCTAssertEqual(fourAccounts.accountListMaxHeight, 232)

        let fiveAccounts = StatusViewModel(
            state: SwitcherooAppState(accounts: [
                makeAccount(name: "One"),
                makeAccount(name: "Two"),
                makeAccount(name: "Three"),
                makeAccount(name: "Four"),
                makeAccount(name: "Five"),
            ]),
            renameDraftAccountId: nil,
            now: now
        )
        XCTAssertEqual(fiveAccounts.accountListMaxHeight, 232)
        XCTAssertEqual(fiveAccounts.footerText, "5 accounts")
    }

    func testExpiryDisplayClassifiesRemainingTime() {
        let expired = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(expired.text, "Expired")
        XCTAssertEqual(expired.kind, .expired)

        let warning = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(300), now: now)
        XCTAssertEqual(warning.text, "5m left")
        XCTAssertEqual(warning.kind, .warning)

        let neutralMinutes = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(901), now: now)
        XCTAssertEqual(neutralMinutes.text, "16m left")
        XCTAssertEqual(neutralMinutes.kind, .neutral)

        let hours = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(7_200), now: now)
        XCTAssertEqual(hours.text, "2h left")
        XCTAssertEqual(hours.kind, .neutral)
    }
}
