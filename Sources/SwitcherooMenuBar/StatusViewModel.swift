import CoreGraphics
import Foundation
import SwitcherooPresentation

struct StatusViewModel: Equatable, Sendable {
    static let popoverWidth: CGFloat = 310

    let title: String
    let versionText: String
    let errorMessage: String?
    let showHeaderActions: Bool
    let isEmpty: Bool
    let emptyState: EmptyState
    let accounts: [Account]
    let footerText: String
    let accountListMaxHeight: CGFloat

    init(state: SwitcherooAppState, renameDraftAccountId: String?, now: Date) {
        self.title = "Switcheroo"
        self.versionText = "v1.0"
        self.errorMessage = state.errorMessage
        self.showHeaderActions = !state.accounts.isEmpty
        self.isEmpty = state.accounts.isEmpty
        self.accounts = state.accounts.map { account in
            let metadata = state.accountMetadataById[account.id]
            return Account(
                id: account.id,
                name: account.name,
                email: metadata?.email,
                isActive: state.activeAccountId == account.id,
                isRenaming: renameDraftAccountId == account.id,
                activeLabel: state.activeAccountId == account.id ? "ACTIVE" : nil,
                expiry: state.accessTokenExpiryByAccountId[account.id].map {
                    ExpiryDisplay.make(expiry: $0, now: now)
                },
                showSwitchAction: state.activeAccountId != account.id
            )
        }
        self.footerText = Self.footerText(accountCount: state.accounts.count)
        self.accountListMaxHeight = Self.accountListMaxHeight(accountCount: state.accounts.count)
        self.emptyState = EmptyState(
            title: "No accounts configured",
            message: "Sync an existing session or log in\nvia Terminal to get started.",
            primaryActionTitle: "Sync current account",
            secondaryActionTitle: "Add new account"
        )
    }

    private static func footerText(accountCount: Int) -> String {
        if accountCount == 0 { return "No active session" }
        return accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    private static func accountListMaxHeight(accountCount: Int) -> CGFloat {
        CGFloat(min(accountCount, 4)) * 55 + 12
    }

    struct EmptyState: Equatable, Sendable {
        let title: String
        let message: String
        let primaryActionTitle: String
        let secondaryActionTitle: String
    }

    struct Account: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let email: String?
        let isActive: Bool
        let isRenaming: Bool
        let activeLabel: String?
        let expiry: ExpiryDisplay?
        let showSwitchAction: Bool
    }

    struct ExpiryDisplay: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case expired
            case warning
            case neutral
        }

        let text: String
        let kind: Kind

        var isExpired: Bool {
            kind == .expired
        }

        static func make(expiry: Date, now: Date) -> ExpiryDisplay {
            let remaining = expiry.timeIntervalSince(now)
            if remaining <= 0 {
                return ExpiryDisplay(text: "Expired", kind: .expired)
            }

            if remaining >= 3600 {
                let hours = max(1, Int((remaining / 3600).rounded()))
                return ExpiryDisplay(text: "\(hours)h left", kind: .neutral)
            }

            let minutes = max(1, Int(ceil(remaining / 60)))
            if remaining <= 600 {
                return ExpiryDisplay(text: "\(minutes)m left", kind: .warning)
            }
            return ExpiryDisplay(text: "\(minutes)m left", kind: .neutral)
        }
    }
}
