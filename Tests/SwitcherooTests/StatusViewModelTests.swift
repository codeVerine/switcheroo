import XCTest
@testable import SwitcherooMenuBar
import SwitcherooCore
import SwitcherooPresentation

final class StatusViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyStateDerivesStaticTextAndFlags() {
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(
                providers: [ProviderDescriptor(id: "codex", displayName: "Codex")]
            ),
            renameDraftAccountId: nil,
            now: now
        )

        XCTAssertEqual(viewModel.title, "Switcheroo")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(viewModel.versionText, "v\(version ?? "0.0.0")")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertFalse(viewModel.showHeaderActions)
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(viewModel.emptyState.title, "No accounts configured")
        XCTAssertEqual(viewModel.emptyState.message, "Import an existing Codex session or add a new account via login flow.")
        XCTAssertEqual(viewModel.emptyState.primaryActionTitle, "Import logged-in account")
        XCTAssertEqual(viewModel.emptyState.secondaryActionTitle, "Add new account")
        XCTAssertEqual(viewModel.footerText, "No accounts added")
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

        let viewModel = StatusViewModel(state: state, renameDraftAccountId: backup.id, statusMessage: "Refreshed Backup.", now: now)

        XCTAssertEqual(viewModel.errorMessage, "Sync failed")
        XCTAssertNil(viewModel.statusMessage)
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
        XCTAssertFalse(activeView.showSwitchAction)
        XCTAssertEqual(activeView.expiry?.text, "2h left")
        XCTAssertEqual(activeView.expiry?.kind, .neutral)

        let backupView = viewModel.accounts[1]
        XCTAssertEqual(backupView.id, backup.id)
        XCTAssertEqual(backupView.email, "backup@example.com")
        XCTAssertFalse(backupView.isActive)
        XCTAssertTrue(backupView.isRenaming)
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

    func testStatusMessageIsVisibleWhenThereIsNoError() {
        let account = makeAccount(id: "acc-1", name: "Primary")
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(accounts: [account]),
            renameDraftAccountId: nil,
            statusMessage: "Refreshed Primary.",
            now: now
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statusMessage, "Refreshed Primary.")
    }

    func testReloginWarningUsesCompactErrorBannerAndHidesStatus() {
        let account = makeAccount(id: "acc-1", name: "Primary")
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(accounts: [account], requiresRelogin: true),
            renameDraftAccountId: nil,
            statusMessage: "Refreshed Primary.",
            now: now
        )

        XCTAssertEqual(viewModel.errorMessage, "Re-login required.")
        XCTAssertNil(viewModel.statusMessage)
    }

    func testExpiryDisplayClassifiesRemainingTime() {
        let expired = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(expired.text, "Expired")
        XCTAssertEqual(expired.kind, .expired)
        XCTAssertEqual(expired.remainingSeconds, 0)

        let warning = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(300), now: now)
        XCTAssertEqual(warning.text, "5m left")
        XCTAssertEqual(warning.kind, .warning)
        XCTAssertEqual(warning.remainingSeconds, 300)

        let neutralMinutes = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(901), now: now)
        XCTAssertEqual(neutralMinutes.text, "16m left")
        XCTAssertEqual(neutralMinutes.kind, .neutral)
        XCTAssertEqual(neutralMinutes.remainingSeconds, 901)

        let hours = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(7_200), now: now)
        XCTAssertEqual(hours.text, "2h left")
        XCTAssertEqual(hours.kind, .neutral)
        XCTAssertEqual(hours.remainingSeconds, 7_200)

        let daysAndHours = StatusViewModel.ExpiryDisplay.make(expiry: now.addingTimeInterval(27 * 3_600), now: now)
        XCTAssertEqual(daysAndHours.text, "1d 3h left")
        XCTAssertEqual(daysAndHours.kind, .neutral)
        XCTAssertEqual(daysAndHours.remainingSeconds, 27 * 3_600)

        let weeksDaysHours = StatusViewModel.ExpiryDisplay.make(
            expiry: now.addingTimeInterval((9 * 24 * 3_600) + (5 * 3_600)),
            now: now
        )
        XCTAssertEqual(weeksDaysHours.text, "1w 2d 5h left")
        XCTAssertEqual(weeksDaysHours.kind, .neutral)
        XCTAssertEqual(weeksDaysHours.remainingSeconds, (9 * 24 * 3_600) + (5 * 3_600))
    }
}
