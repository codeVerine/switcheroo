import XCTest
import SwiftUI
@testable import SwitcherooMenuBar
import SwitcherooCore
import SwitcherooPresentation

@MainActor
final class StatusViewTests: XCTestCase {
    func testStatusViewBodyBuildsForEmptyAndPopulatedStates() {
        let emptyModel = AppModel(app: MockSwitcherooApp(), startTimers: false)
        emptyModel.statusMessage = "Imported account."
        let emptyView = StatusView(model: emptyModel, onQuit: {})
        _ = emptyView.body

        let emptyErrorModel = AppModel(
            app: MockSwitcherooApp(state: SwitcherooAppState(errorMessage: "Missing auth file")),
            startTimers: false
        )
        let emptyErrorView = StatusView(model: emptyErrorModel, onQuit: {})
        _ = emptyErrorView.body

        let account = makeAccount(id: "acc-1", name: "Alpha")
        let populatedApp = MockSwitcherooApp(
            state: SwitcherooAppState(
                errorMessage: "Sync failed",
                accounts: [account],
                activeAccountId: account.id,
                accessTokenExpiryByAccountId: [
                    account.id: Date(timeIntervalSince1970: 1_700_007_200),
                ],
                accountMetadataById: [
                    account.id: SwitcherooAccountMetadata(email: "alpha@example.com"),
                ]
            )
        )
        let populatedModel = AppModel(app: populatedApp, startTimers: false)
        populatedModel.renameDraftAccountId = account.id
        populatedModel.renameDraftText = "Alpha"

        let populatedView = StatusView(model: populatedModel, onQuit: {})
        _ = populatedView.body
    }

    func testAccountRowBodyBuildsForActiveAndRenamingStates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = SwitcherooAppState(
            accounts: [makeAccount(id: "acc-1", name: "Alpha")],
            activeAccountId: "acc-1",
            accessTokenExpiryByAccountId: [
                "acc-1": now.addingTimeInterval(7_200),
            ],
            accountMetadataById: [
                "acc-1": SwitcherooAccountMetadata(email: "alpha@example.com"),
            ]
        )

        let activeViewModel = StatusViewModel(state: state, renameDraftAccountId: nil, now: now)
        let activeRow = AccountRow(
            account: activeViewModel.accounts[0],
            renameText: .constant("Alpha"),
            onSwitch: {},
            onRename: {},
            onSaveRename: {},
            onCancelRename: {},
            onDelete: {}
        )
        _ = activeRow.body

        let renamingViewModel = StatusViewModel(state: state, renameDraftAccountId: "acc-1", now: now)
        let renamingRow = AccountRow(
            account: renamingViewModel.accounts[0],
            renameText: .constant(""),
            onSwitch: {},
            onRename: {},
            onSaveRename: {},
            onCancelRename: {},
            onDelete: {}
        )
        _ = renamingRow.body
    }

    func testButtonHelpersBuildForAllVariants() {
        let ctaPrimary = CtaButton(title: "Sync", icon: .sync, variant: .primary, action: {})
        _ = ctaPrimary.body

        let ctaSecondary = CtaButton(title: "Add", icon: .terminal, variant: .secondary, action: {})
        _ = ctaSecondary.body

        let defaultIconButton = IconButton(icon: .sync, tooltip: "Sync", action: {})
        _ = defaultIconButton.body

        let importIconButton = IconButton(icon: .importCurrent, tooltip: "Import logged-in account", action: {})
        _ = importIconButton.body

        let dangerIconButton = IconButton(icon: .trash, tooltip: "Delete", variant: .danger, action: {})
        _ = dangerIconButton.body

        let confirmIconButton = IconButton(icon: .check, tooltip: "Save", variant: .confirm, size: 22, action: {})
        _ = confirmIconButton.body
    }
}
