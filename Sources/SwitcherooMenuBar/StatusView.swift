import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let onQuit: () -> Void

    var body: some View {
        let now = Date()
        let viewModel = StatusViewModel(
            state: model.state,
            renameDraftAccountId: model.renameDraftAccountId,
            statusMessage: model.statusMessage,
            now: now
        )

        VStack(spacing: 0) {
            header(viewModel)
            separator(horizontalInset: 10)
            messageBanner(viewModel)
                .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
                .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)

            if viewModel.isEmpty {
                emptyState(viewModel)
            } else {
                accountList(viewModel)
            }

            separator(horizontalInset: 0)
            footer(viewModel)
        }
        .background(.ultraThinMaterial)
        .background(Theme.popoverBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.popoverBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
        .frame(width: StatusViewModel.popoverWidth)
    }

    private func header(_ viewModel: StatusViewModel) -> some View {
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

                Text(viewModel.title)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.26)
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer()

            if viewModel.showHeaderActions {
                HStack(spacing: 2) {
                    IconButton(
                        icon: .importCurrent,
                        tooltip: viewModel.emptyState.primaryActionTitle
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

    private func accountList(_ viewModel: StatusViewModel) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(viewModel.accounts) { account in
                    AccountRow(
                        account: account,
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
        .frame(maxHeight: viewModel.accountListMaxHeight)
    }

    @ViewBuilder
    private func messageBanner(_ viewModel: StatusViewModel) -> some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let statusMessage = viewModel.statusMessage {
            Text(statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func emptyState(_ viewModel: StatusViewModel) -> some View {
        VStack(spacing: 16) {
            IconGlyph(.empty, size: 36)
                .foregroundStyle(Theme.textQuaternary)

            VStack(spacing: 4) {
                Text(viewModel.emptyState.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                Text(viewModel.emptyState.message)
                    .font(.system(size: 11, weight: .regular))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 6) {
                CtaButton(title: viewModel.emptyState.primaryActionTitle, icon: .importCurrent, variant: .primary) {
                    model.importCurrentAccount()
                }

                CtaButton(title: viewModel.emptyState.secondaryActionTitle, icon: .terminal, variant: .secondary) {
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

    private func footer(_ viewModel: StatusViewModel) -> some View {
        HStack(spacing: 0) {
            Text(viewModel.footerText)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.1)
                .foregroundStyle(Theme.textQuaternary)

            Spacer()

            Text(viewModel.versionText)
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

    private func separator(horizontalInset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, horizontalInset)
    }
}

struct AccountRow: View {
    let account: StatusViewModel.Account
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

            if account.isRenaming {
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

                if isHovering || account.isActive {
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
        .animation(.easeOut(duration: 0.1), value: account.isActive)
        .onHover { isHovering = $0 }
    }

    private var statusDot: some View {
        Circle()
            .fill(account.isActive ? Theme.accent : .clear)
            .overlay(
                Circle()
                    .stroke(account.isActive ? .clear : Theme.borderSecondary, lineWidth: 1.5)
            )
            .shadow(color: account.isActive ? Theme.accentGlow : .clear, radius: 3)
            .frame(width: 6, height: 6)
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.125)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let activeLabel = account.activeLabel {
                    Text(activeLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.475)
                        .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 8) {
                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 10.5, weight: .regular))
                        .tracking(0.0525)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                if let expiry = account.expiry {
                    if expiry.isExpired {
                        IconGlyph(.alert, size: 10)
                            .foregroundStyle(expiryColor(for: expiry.kind))
                            .help(expiryTooltip(for: expiry))
                    } else if expiry.remainingSeconds < 24 * 3600 {
                        IconGlyph(.clock, size: 10)
                            .foregroundStyle(expiryColor(for: expiry.kind))
                            .help(expiryTooltip(for: expiry))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if account.showSwitchAction {
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
        if account.isActive { return Theme.rowActiveBg }
        if isHovering { return Theme.rowHover }
        return .clear
    }

    private func expiryColor(for kind: StatusViewModel.ExpiryDisplay.Kind) -> Color {
        switch kind {
        case .expired:
            return Theme.danger
        case .warning:
            return Theme.warning
        case .neutral:
            return Theme.textTertiary
        }
    }

    private func expiryTooltip(for expiry: StatusViewModel.ExpiryDisplay) -> String {
        if expiry.isExpired {
            return "Access token expired"
        }

        // `ExpiryDisplay.text` is already short (ex: "5m left", "1d 3h left").
        // We want a clearer tooltip message without changing the underlying model contract.
        let suffix = " left"
        let remaining = expiry.text.hasSuffix(suffix) ? String(expiry.text.dropLast(suffix.count)) : expiry.text
        return "Access token expires in \(remaining)"
    }
}

struct CtaButton: View {
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

struct IconButton: View {
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
        case .importCurrent:
            return "tray.and.arrow.down"
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
        case .importCurrent, .sync, .terminal:
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

enum IconKind {
    case importCurrent
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
        case .importCurrent:
            return "tray.and.arrow.down"
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
