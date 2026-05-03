import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let onQuit: () -> Void

    var body: some View {
        let now = Date()

        VStack(spacing: 0) {
            header
            separator(horizontalInset: 10)

            if model.state.accounts.isEmpty {
                emptyState
            } else {
                accountList(now: now)
            }

            separator(horizontalInset: 0)
            footer
        }
        .background(.ultraThinMaterial)
        .background(Theme.popoverBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.popoverBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Color(red: 31 / 255, green: 107 / 255, blue: 90 / 255)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    IconGlyph(.switch, size: 13)
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)

                Text("Switcheroo")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.26)
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer()

            if !model.state.accounts.isEmpty {
                HStack(spacing: 2) {
                    IconButton(
                        icon: .sync,
                        tooltip: "Sync current account"
                    ) {
                        model.importCurrentAccount()
                    }
                    IconButton(
                        icon: .plus,
                        tooltip: "Add account (codex login)"
                    ) {
                        model.startAddAccount()
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.leading, 12)
        .padding(.bottom, 8)
        .padding(.trailing, 12)
    }

    private func accountList(now: Date) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if let errorMessage = model.state.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }

                ForEach(model.state.accounts) { account in
                    AccountRow(
                        accountId: account.id,
                        accountName: account.name,
                        email: model.state.accountMetadataById[account.id]?.email,
                        isActive: model.state.activeAccountId == account.id,
                        expiry: model.state.accessTokenExpiryByAccountId[account.id],
                        now: now,
                        isRenaming: model.renameDraftAccountId == account.id,
                        renameText: $model.renameDraftText,
                        onSwitch: {
                            model.switchToAccount(account.id)
                        },
                        onRename: {
                            model.startRenameDraft(accountId: account.id, currentName: account.name)
                        },
                        onSaveRename: {
                            model.saveRenameDraft()
                        },
                        onCancelRename: {
                            model.cancelRenameDraft()
                        },
                        onDelete: {
                            model.deleteAccount(account.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: accountListMaxHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            IconGlyph(.empty, size: 36)
                .foregroundStyle(Theme.textQuaternary)

            VStack(spacing: 4) {
                Text("No accounts configured")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                Text("Sync an existing session or log in\nvia Terminal to get started.")
                    .font(.system(size: 11, weight: .regular))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 6) {
                CtaButton(title: "Sync current account", icon: .sync, variant: .primary) {
                    model.importCurrentAccount()
                }

                CtaButton(title: "Add new account", icon: .terminal, variant: .secondary) {
                    model.startAddAccount()
                }
            }
            .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(footerText)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.1)
                .foregroundStyle(Theme.textQuaternary)

            Spacer()

            Text("v1.0")
                .font(.system(size: 10, weight: .medium))
                .tracking(0.1)
                .foregroundStyle(Theme.textQuaternary)
                .padding(.trailing, 4)

            IconButton(
                icon: .power,
                tooltip: "Quit Switcheroo",
                variant: .danger,
                size: 22,
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onQuit()
                }
            }
        }
        .padding(.top, 5)
        .padding(.trailing, 10)
        .padding(.bottom, 5)
        .padding(.leading, 12)
    }

    private var footerText: String {
        let count = model.state.accounts.count
        if count == 0 { return "No active session" }
        return count == 1 ? "1 account" : "\(count) accounts"
    }

    private var accountListMaxHeight: CGFloat {
        CGFloat(min(model.state.accounts.count, 4)) * 55 + 12
    }

    private func separator(horizontalInset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, horizontalInset)
    }

}

private struct AccountRow: View {
    let accountId: String
    let accountName: String
    let email: String?
    let isActive: Bool
    let expiry: Date?
    let now: Date
    let isRenaming: Bool
    @Binding var renameText: String
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onSaveRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            statusDot

            if isRenaming {
                HStack(spacing: 4) {
                    TextField("", text: $renameText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Theme.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.accent, lineWidth: 1)
                        )
                    .onSubmit(onSaveRename)
                    .onExitCommand(perform: onCancelRename)

                    IconButton(
                        icon: .check,
                        tooltip: "Save",
                        variant: .confirm,
                        size: 22,
                        action: onSaveRename
                    )
                    IconButton(
                        icon: .close,
                        tooltip: "Cancel",
                        size: 22,
                        action: onCancelRename
                    )
                }
            } else {
                infoBlock

                if isHovering || isActive {
                    actions
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isActive)
        .onHover { isHovering = $0 }
    }

    private var statusDot: some View {
        Circle()
            .fill(isActive ? Theme.accent : .clear)
            .overlay(
                Circle()
                    .stroke(isActive ? .clear : Theme.borderSecondary, lineWidth: 1.5)
            )
            .shadow(color: isActive ? Theme.accentGlow : .clear, radius: 3)
            .frame(width: 6, height: 6)
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(accountName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.125)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.475)
                        .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 8) {
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 10.5, weight: .regular))
                        .tracking(0.0525)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                if let expiryDisplay {
                    HStack(spacing: 3) {
                        IconGlyph(expiryDisplay.isExpired ? .alert : .clock, size: 10)
                        Text(expiryDisplay.text)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.105)
                    .foregroundStyle(expiryDisplay.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !isActive {
                IconButton(
                    icon: .switch,
                    tooltip: "Switch to this account",
                    action: onSwitch
                )
            }
            IconButton(
                icon: .pencil,
                tooltip: "Rename",
                action: onRename
            )
            IconButton(
                icon: .trash,
                tooltip: "Delete",
                variant: .danger,
                action: onDelete
            )
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.rowActiveBg }
        if isHovering { return Theme.rowHover }
        return .clear
    }

    private var expiryDisplay: ExpiryDisplay? {
        guard let expiry else { return nil }

        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 {
            return ExpiryDisplay(text: "Expired", color: Theme.danger, isExpired: true)
        }

        if remaining >= 3600 {
            let hours = max(1, Int((remaining / 3600).rounded()))
            return ExpiryDisplay(text: "\(hours)h left", color: Theme.textTertiary, isExpired: false)
        }

        let minutes = max(1, Int(ceil(remaining / 60)))
        let color = remaining <= 600 ? Theme.warning : Theme.textTertiary
        return ExpiryDisplay(text: "\(minutes)m left", color: color, isExpired: false)
    }
}

private struct ExpiryDisplay {
    let text: String
    let color: Color
    let isExpired: Bool
}

private struct CtaButton: View {
    enum Variant {
        case primary
        case secondary
    }

    let title: String
    let icon: IconKind
    let variant: Variant
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                IconGlyph(icon, size: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.06)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(border, lineWidth: variant == .secondary ? 1 : 0)
            )
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var foreground: Color {
        variant == .primary ? .white : Theme.textSecondary
    }

    private var background: Color {
        switch variant {
        case .primary:
            return isHovering ? Theme.accentHover : Theme.accent
        case .secondary:
            return isHovering ? Theme.buttonHover : .clear
        }
    }

    private var border: Color {
        variant == .secondary ? Theme.borderPrimary : .clear
    }
}

private struct IconButton: View {
    enum Variant {
        case `default`
        case danger
        case confirm
    }

    let icon: IconKind
    let tooltip: String
    var variant: Variant = .default
    var size: CGFloat = 24
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        NativeIconButton(
            systemName: systemName,
            tooltip: tooltip,
            symbolPointSize: iconSize,
            foregroundColor: foreground,
            backgroundColor: background,
            isHovering: $isHovering,
            action: action
        )
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var systemName: String {
        switch icon {
        case .switch:
            return "arrow.left.arrow.right"
        case .pencil:
            return "pencil"
        case .trash:
            return "trash"
        case .sync:
            return "arrow.clockwise"
        case .plus:
            return "plus"
        case .terminal:
            return "terminal"
        case .clock:
            return "clock"
        case .alert:
            return "exclamationmark.triangle"
        case .close:
            return "xmark"
        case .check:
            return "checkmark"
        case .empty:
            return "plus.rectangle.on.folder"
        case .power:
            return "power"
        }
    }

    private var iconSize: CGFloat {
        switch icon {
        case .sync, .terminal:
            return 14
        case .check, .power:
            return 11
        case .close, .clock, .alert:
            return 10
        default:
            return 13
        }
    }

    private var foreground: Color {
        switch variant {
        case .default:
            return Theme.textSecondary
        case .danger:
            return isHovering ? Theme.danger : Theme.textTertiary
        case .confirm:
            return .white
        }
    }

    private var background: Color {
        switch variant {
        case .default:
            return isHovering ? Theme.buttonHover : .clear
        case .danger:
            return isHovering ? Theme.dangerBg : .clear
        case .confirm:
            return isHovering ? Theme.confirmHover : Theme.confirm
        }
    }
}

private enum IconKind {
    case `switch`
    case pencil
    case trash
    case sync
    case plus
    case terminal
    case clock
    case alert
    case close
    case check
    case empty
    case power
}

private struct IconGlyph: View {
    let kind: IconKind
    let size: CGFloat

    init(_ kind: IconKind, size: CGFloat) {
        self.kind = kind
        self.size = size
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .frame(width: size, height: size)
    }

    private var systemName: String {
        switch kind {
        case .switch:
            return "arrow.left.arrow.right"
        case .pencil:
            return "pencil"
        case .trash:
            return "trash"
        case .sync:
            return "arrow.clockwise"
        case .plus:
            return "plus"
        case .terminal:
            return "terminal"
        case .clock:
            return "clock"
        case .alert:
            return "exclamationmark.triangle"
        case .close:
            return "xmark"
        case .check:
            return "checkmark"
        case .empty:
            return "plus.rectangle.on.folder"
        case .power:
            return "power"
        }
    }
}

private enum Theme {
    static let popoverBg = Color(red: 36 / 255, green: 36 / 255, blue: 40 / 255).opacity(0.96)
    static let popoverBorder = Color.white.opacity(0.08)
    static let accent = Color(red: 45 / 255, green: 140 / 255, blue: 120 / 255)
    static let accentHover = Color(red: 52 / 255, green: 160 / 255, blue: 138 / 255)
    static let accentGlow = Color(red: 45 / 255, green: 140 / 255, blue: 120 / 255).opacity(0.4)
    static let rowActiveBg = Color(red: 45 / 255, green: 140 / 255, blue: 120 / 255).opacity(0.08)
    static let rowHover = Color.white.opacity(0.04)
    static let buttonHover = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.40)
    static let textQuaternary = Color.white.opacity(0.18)
    static let borderPrimary = Color.white.opacity(0.10)
    static let borderSecondary = Color.white.opacity(0.15)
    static let inputBg = Color.black.opacity(0.25)
    static let separator = Color.white.opacity(0.06)
    static let danger = Color(red: 214 / 255, green: 69 / 255, blue: 69 / 255)
    static let dangerBg = Color(red: 214 / 255, green: 69 / 255, blue: 69 / 255).opacity(0.1)
    static let warning = Color(red: 200 / 255, green: 122 / 255, blue: 32 / 255)
    static let confirm = Color(red: 52 / 255, green: 179 / 255, blue: 102 / 255)
    static let confirmHover = Color(red: 46 / 255, green: 165 / 255, blue: 94 / 255)
}
