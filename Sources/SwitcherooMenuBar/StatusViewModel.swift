import CoreGraphics
import Foundation
import SwitcherooPresentation

struct StatusViewModel: Equatable, Sendable {
    static let popoverWidth: CGFloat = 310

    let title: String
    let versionText: String
    let errorMessage: String?
    let statusMessage: String?
    let showHeaderActions: Bool
    let isEmpty: Bool
    let emptyState: EmptyState
    let accounts: [Account]
    let footerText: String
    let accountListMaxHeight: CGFloat

    init(state: SwitcherooAppState, renameDraftAccountId: String?, statusMessage: String? = nil, now: Date) {
        self.title = "Switcheroo"
        self.versionText = "v1.0"
        self.errorMessage = state.errorMessage
        self.statusMessage = state.errorMessage == nil ? statusMessage : nil
        self.showHeaderActions = !state.accounts.isEmpty
        self.isEmpty = state.accounts.isEmpty
        let providerDisplayName = Self.providerDisplayName(state: state)
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
            message: "Import the account currently logged into \(providerDisplayName) on this Mac.\nOr log in via Terminal to add a new account.",
            primaryActionTitle: "Import logged-in account",
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

    private static func providerDisplayName(state: SwitcherooAppState) -> String {
        if let selectedProviderId = state.selectedProviderId,
           let selectedProvider = state.providers.first(where: { $0.id == selectedProviderId }) {
            return selectedProvider.displayName
        }

        if state.providers.count == 1, let provider = state.providers.first {
            return provider.displayName
        }

        return "the selected provider"
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
        let remainingSeconds: Int

        var isExpired: Bool {
            kind == .expired
        }

        static func make(expiry: Date, now: Date) -> ExpiryDisplay {
            let remainingInterval = expiry.timeIntervalSince(now)
            let remainingSeconds = max(0, Int(remainingInterval))
            if remainingInterval <= 0 {
                return ExpiryDisplay(text: "Expired", kind: .expired, remainingSeconds: 0)
            }

            if remainingInterval >= 3600 {
                let hours = max(1, Int((remainingInterval / 3600).rounded()))
                return ExpiryDisplay(text: "\(formatHours(hours)) left", kind: .neutral, remainingSeconds: remainingSeconds)
            }

            let minutes = max(1, Int(ceil(remainingInterval / 60)))
            if remainingInterval <= 600 {
                return ExpiryDisplay(text: "\(minutes)m left", kind: .warning, remainingSeconds: remainingSeconds)
            }
            return ExpiryDisplay(text: "\(minutes)m left", kind: .neutral, remainingSeconds: remainingSeconds)
        }

        private static func formatHours(_ totalHours: Int) -> String {
            let hoursPerDay = 24
            let hoursPerWeek = hoursPerDay * 7

            let weeks = totalHours / hoursPerWeek
            let days = (totalHours % hoursPerWeek) / hoursPerDay
            let hours = totalHours % hoursPerDay

            var parts: [String] = []
            if weeks > 0 { parts.append("\(weeks)w") }
            if days > 0 { parts.append("\(days)d") }
            if hours > 0 || parts.isEmpty { parts.append("\(hours)h") }

            return parts.joined(separator: " ")
        }
    }
}
