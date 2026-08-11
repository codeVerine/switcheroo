import CoreGraphics
import Foundation
import SwitcherooCore
import SwitcherooPresentation

struct StatusViewModel: Equatable, Sendable {
    static let popoverWidth: CGFloat = 300
    static let accountRowHeight: CGFloat = 66
    static let accountRowSpacing: CGFloat = 6
    static let accountListVerticalPadding: CGFloat = 16

    let title: String
    let versionText: String
    let errorMessage: String?
    let statusMessage: String?
    let showHeaderActions: Bool
    let canImportCurrentAccount: Bool
    let isEmpty: Bool
    let emptyState: EmptyState
    let accounts: [Account]
    let footerText: String
    let accountListMaxHeight: CGFloat

    init(state: SwitcherooAppState, renameDraftAccountId: String?, statusMessage: String? = nil, now: Date, timeZone: TimeZone = .current) {
        self.title = "Switcheroo"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.versionText = "v\(version ?? "0.0.0")"
        let rawError = state.errorMessage ?? (state.requiresRelogin ? "Re-login required." : nil)
        let isMissingActiveAuthFile = Self.isMissingActiveAuthFileError(rawError)
        self.errorMessage = isMissingActiveAuthFile ? nil : rawError
        self.statusMessage = rawError == nil ? statusMessage : nil
        self.showHeaderActions = !state.accounts.isEmpty
        self.canImportCurrentAccount = !isMissingActiveAuthFile
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
                expiry: state.accessTokenExpiryByAccountId[account.id].map {
                    ExpiryDisplay.make(expiry: $0, now: now)
                },
                usage: UsageDisplay.make(
                    state: state.usageStatesByAccountId[account.id] ?? .notRequested,
                    now: now,
                    timeZone: timeZone
                ),
                showSwitchAction: state.activeAccountId != account.id
            )
        }
        self.footerText = Self.footerText(accountCount: state.accounts.count)
        self.accountListMaxHeight = Self.accountListMaxHeight(accountCount: state.accounts.count)
        self.emptyState = EmptyState(
            title: "No accounts configured",
            message: Self.emptyStateMessage(
                providerDisplayName: providerDisplayName,
                isMissingActiveAuthFile: isMissingActiveAuthFile
            ),
            primaryActionTitle: "Import logged-in account",
            secondaryActionTitle: "Add new account"
        )
    }

    private static func footerText(accountCount: Int) -> String {
        if accountCount == 0 { return "No accounts added" }
        return accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    private static func accountListMaxHeight(accountCount: Int) -> CGFloat {
        let visibleRows = min(accountCount, 4)
        guard visibleRows > 0 else { return 12 }

        let rowHeight = CGFloat(visibleRows) * accountRowHeight
        let rowSpacing = CGFloat(visibleRows - 1) * accountRowSpacing
        return rowHeight + rowSpacing + accountListVerticalPadding
    }

    private static func isMissingActiveAuthFileError(_ errorMessage: String?) -> Bool {
        errorMessage?.hasPrefix("Missing auth file at ") == true
    }

    private static func emptyStateMessage(providerDisplayName: String, isMissingActiveAuthFile: Bool) -> String {
        if isMissingActiveAuthFile {
            return "No active session is present to import. Log in to Codex via Add new account."
        }

        return "Import an existing \(providerDisplayName) session or add a new account via login flow."
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
        let expiry: ExpiryDisplay?
        let usage: UsageDisplay?
        let showSwitchAction: Bool
    }

    /// Usage information shown under each account row. Each applicable
    /// usage window (five-hour, weekly) renders its own compact line with
    /// the remaining percentage and the reset date/time visible inline.
    struct UsageDisplay: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case loaded
            case loading
            case unavailable
        }

        /// Semantic color token so the menu bar can style usage rows without
        /// baking AppKit colors into the view model. Low-balance rows render
        /// red (danger); unavailable rows keep the orange warning.
        enum ColorToken: Equatable, Sendable {
            case textSecondary
            case textTertiary
            case warning
            case danger
        }

        /// One window line rendered directly in the dropdown.
        struct WindowLine: Identifiable, Equatable, Sendable {
            /// Stable identifier for SwiftUI iteration: the window label ("5h" / "1w").
            public let id: String
            /// Compact line text: e.g. "5h 58% — resets Mon 3:15 PM"
            public let text: String
            /// Per-window color: danger when that window is below 25% remaining.
            public let colorToken: ColorToken
        }

        let kind: Kind
        /// Per-window lines rendered inline in the dropdown; the reset
        /// date/time is visible in each line without requiring a hover.
        let windows: [WindowLine]
        /// One-line summary for non-loaded states (loading / unavailable).
        let text: String
        /// Tooltip detail: reset timing for loaded usage, or the (secret-free)
        /// reason for unavailable usage.
        let detail: String?
        /// True when any window has less than 25% remaining.
        let hasLowRemaining: Bool

        /// Aggregate color for the legacy single-line path (loading / unavailable).
        var colorToken: ColorToken {
            switch kind {
            case .loaded:
                return hasLowRemaining ? .danger : .textSecondary
            case .loading:
                return .textTertiary
            case .unavailable:
                return .warning
            }
        }

        private static let lowRemainingThreshold = 25.0

        static func make(state: SwitcherooAccountUsageState, now: Date, timeZone: TimeZone = .current) -> UsageDisplay? {
            switch state {
            case .notRequested:
                return nil
            case .loading:
                return UsageDisplay(
                    kind: .loading,
                    windows: [],
                    text: "Checking usage…",
                    detail: nil,
                    hasLowRemaining: false
                )
            case .unavailable(let reason):
                return UsageDisplay(
                    kind: .unavailable,
                    windows: [],
                    text: "Usage unavailable",
                    detail: reason,
                    hasLowRemaining: false
                )
            case .loaded(let usage):
                let fiveHourLine = usage.fiveHour.map {
                    WindowLine(
                        id: "5h",
                        text: Self.windowLineText(label: "5h", window: $0, now: now, timeZone: timeZone),
                        colorToken: $0.remainingPercent < lowRemainingThreshold ? .danger : .textSecondary
                    )
                }
                let weeklyLine = usage.weekly.map {
                    WindowLine(
                        id: "1w",
                        text: Self.windowLineText(label: "1w", window: $0, now: now, timeZone: timeZone),
                        colorToken: $0.remainingPercent < lowRemainingThreshold ? .danger : .textSecondary
                    )
                }
                let windowLines = [fiveHourLine, weeklyLine].compactMap { $0 }
                guard !windowLines.isEmpty else { return nil }
                let lowRemaining = (usage.fiveHour?.remainingPercent ?? 100) < lowRemainingThreshold
                    || (usage.weekly?.remainingPercent ?? 100) < lowRemainingThreshold
                return UsageDisplay(
                    kind: .loaded,
                    windows: windowLines,
                    text: windowLines.map(\.text).joined(separator: "\n"),
                    detail: Self.detailText(fiveHour: usage.fiveHour, weekly: usage.weekly, now: now),
                    hasLowRemaining: lowRemaining
                )
            }
        }

        /// Builds one compact window line: "5h 58% — resets Mon 3:15 PM".
        /// When `resetsAt` is nil the reset portion is omitted.
        private static func windowLineText(label: String, window: SwitcherooUsageWindow, now: Date, timeZone: TimeZone) -> String {
            var text = "\(label) \(percent(window.remainingPercent))"
            if let resetsAt = window.resetsAt {
                text += " — resets \(Self.formattedDateTime(resetsAt, timeZone: timeZone))"
            }
            return text
        }

        private static func percent(_ value: Double) -> String {
            "\(Int(value.rounded()))%"
        }

        private static func detailText(fiveHour: SwitcherooUsageWindow?, weekly: SwitcherooUsageWindow?, now: Date) -> String? {
            let clauses = [
                fiveHour.map { Self.clause(label: "Five-hour", window: $0, now: now) },
                weekly.map { Self.clause(label: "Weekly", window: $0, now: now) },
            ].compactMap { $0 }
            return clauses.isEmpty ? nil : clauses.joined(separator: " · ")
        }

        private static func clause(label: String, window: SwitcherooUsageWindow, now: Date) -> String {
            var text = "\(label): \(percent(window.remainingPercent)) remaining"
            if let resetsAt = window.resetsAt {
                text += ", resets \(Self.relativeResetText(resetsAt: resetsAt, now: now))"
            }
            return text
        }

        /// Relative reset description for tooltip detail (e.g. "in 2h").
        private static func relativeResetText(resetsAt: Date, now: Date) -> String {
            let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
            if seconds < 60 { return "now" }
            let minutes = (seconds + 59) / 60
            if minutes < 60 { return "in \(minutes)m" }
            let hours = (minutes + 59) / 60
            if hours < 24 { return "in \(hours)h" }
            let days = (hours + 23) / 24
            return "in \(days)d"
        }

        /// Formats a reset date/time in the user's local time zone.
        /// Compact format: "Mon 3:15 PM" (day-of-week abbreviation + time).
        /// Tests override the time zone to UTC for deterministic output.
        static func formattedDateTime(_ date: Date, timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEE h:mm a"
            return formatter.string(from: date)
        }
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
