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
        XCTAssertTrue(viewModel.canImportCurrentAccount)
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
        XCTAssertEqual(oneAccount.accountListMaxHeight, 74)

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
        XCTAssertEqual(fourAccounts.accountListMaxHeight, 266)

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
        XCTAssertEqual(fiveAccounts.accountListMaxHeight, 266)
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

    func testMissingAuthFileErrorUpdatesEmptyStateMessageAndDisablesImport() {
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(errorMessage: "Missing auth file at /Users/sagar/.codex/auth.json."),
            renameDraftAccountId: nil,
            statusMessage: "Imported account.",
            now: now
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertEqual(viewModel.emptyState.message, "No active session is present to import. Log in to Codex via Add new account.")
        XCTAssertFalse(viewModel.canImportCurrentAccount)
    }

    func testMissingAuthFileErrorWithAccountsSuppressesBannerAndDisablesImport() {
        let account = makeAccount(id: "acc-1", name: "Primary")
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(
                errorMessage: "Missing auth file at /Users/sagar/.codex/auth.json.",
                accounts: [account],
                activeAccountId: account.id
            ),
            renameDraftAccountId: nil,
            now: now
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertFalse(viewModel.isEmpty)
        XCTAssertFalse(viewModel.canImportCurrentAccount)
    }

    func testOtherErrorsKeepOriginalMessageAndImportEnabled() {
        let viewModel = StatusViewModel(
            state: SwitcherooAppState(
                errorMessage: "Invalid auth file at /Users/sagar/.codex/auth.json.",
                providers: [ProviderDescriptor(id: "codex", displayName: "Codex")]
            ),
            renameDraftAccountId: nil,
            now: now
        )

        XCTAssertEqual(viewModel.errorMessage, "Invalid auth file at /Users/sagar/.codex/auth.json.")
        XCTAssertEqual(viewModel.emptyState.message, "Import an existing Codex session or add a new account via login flow.")
        XCTAssertTrue(viewModel.canImportCurrentAccount)
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
        XCTAssertTrue(viewModel.canImportCurrentAccount)
    }

    func testUsageDisplayShownOnlyForActiveAccount() {
        let active = makeAccount(id: "acc-1", name: "Primary")
        let backup = makeAccount(id: "acc-2", name: "Backup")
        let usage = SwitcherooAccountUsage(
            accountId: "acc-1",
            fiveHour: SwitcherooUsageWindow(usedPercent: 42, remainingPercent: 58, windowSeconds: 18_000, resetsAt: nil),
            weekly: SwitcherooUsageWindow(usedPercent: 40, remainingPercent: 60, windowSeconds: 604_800, resetsAt: nil),
            fetchedAt: now
        )
        let state = SwitcherooAppState(
            accounts: [active, backup],
            activeAccountId: active.id,
            usageStatesByAccountId: [active.id: .loaded(usage)]
        )

        let viewModel = StatusViewModel(state: state, renameDraftAccountId: nil, now: now)

        XCTAssertEqual(viewModel.accounts[0].usage?.text, "5h 58% · 1w 60%")
        XCTAssertEqual(viewModel.accounts[0].usage?.kind, .loaded)
        XCTAssertFalse(viewModel.accounts[0].usage?.hasLowRemaining ?? true)
        XCTAssertNil(viewModel.accounts[1].usage)
    }

    func testUsageDisplayLoadingAndUnavailableStates() {
        let active = makeAccount(id: "acc-1", name: "Primary")
        let loadingState = SwitcherooAppState(
            accounts: [active],
            activeAccountId: active.id,
            usageStatesByAccountId: [active.id: .loading]
        )
        let loading = StatusViewModel(state: loadingState, renameDraftAccountId: nil, now: now)
        XCTAssertEqual(loading.accounts[0].usage?.text, "Checking usage…")
        XCTAssertEqual(loading.accounts[0].usage?.kind, .loading)

        let unavailableState = SwitcherooAppState(
            accounts: [active],
            activeAccountId: active.id,
            usageStatesByAccountId: [active.id: .unavailable(reason: "Could not reach the usage service (offline?)")]
        )
        let unavailable = StatusViewModel(state: unavailableState, renameDraftAccountId: nil, now: now)
        XCTAssertEqual(unavailable.accounts[0].usage?.text, "Usage unavailable")
        XCTAssertEqual(unavailable.accounts[0].usage?.kind, .unavailable)
        XCTAssertEqual(unavailable.accounts[0].usage?.detail, "Could not reach the usage service (offline?)")
    }

    func testUsageDisplayFlagsLowRemainingAndIncludesResetDetail() {
        let active = makeAccount(id: "acc-1", name: "Primary")
        let usage = SwitcherooAccountUsage(
            accountId: "acc-1",
            fiveHour: SwitcherooUsageWindow(usedPercent: 90, remainingPercent: 10, windowSeconds: 18_000, resetsAt: now.addingTimeInterval(7_200)),
            weekly: SwitcherooUsageWindow(usedPercent: 84, remainingPercent: 16, windowSeconds: 604_800, resetsAt: now.addingTimeInterval(4 * 86_400)),
            fetchedAt: now
        )
        let state = SwitcherooAppState(
            accounts: [active],
            activeAccountId: active.id,
            usageStatesByAccountId: [active.id: .loaded(usage)]
        )

        let viewModel = StatusViewModel(state: state, renameDraftAccountId: nil, now: now)

        XCTAssertTrue(viewModel.accounts[0].usage?.hasLowRemaining ?? false)
        XCTAssertEqual(
            viewModel.accounts[0].usage?.detail,
            "Five-hour: 10% remaining, resets in 2h · Weekly: 16% remaining, resets in 4d"
        )
    }

    func testUsageDisplayNotRequestedHidesLine() {
        let active = makeAccount(id: "acc-1", name: "Primary")
        let state = SwitcherooAppState(
            accounts: [active],
            activeAccountId: active.id,
            usageStatesByAccountId: [active.id: .notRequested]
        )

        let viewModel = StatusViewModel(state: state, renameDraftAccountId: nil, now: now)

        XCTAssertNil(viewModel.accounts[0].usage)
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
