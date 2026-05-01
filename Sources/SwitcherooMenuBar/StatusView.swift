import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let errorMessage = model.state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.state.accounts.isEmpty {
                Text("No accounts configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Active: \(model.state.statusText)")
                    .font(.subheadline)
            }

            accountList

            Divider()

            actions

            if let hint = model.state.pendingHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Switcheroo")
                .font(.headline)
            Spacer()
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.state.accounts.isEmpty {
                Text("Accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(model.state.accounts) { acc in
                    HStack(spacing: 8) {
                        if model.renameDraftAccountId == acc.id {
                            TextField(
                                "",
                                text: $model.renameDraftText,
                                prompt: Text(model.renameDraftPlaceholder)
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.saveRenameDraft() }
                        } else {
                            HStack(spacing: 4) {
                                Text(acc.name)
                                    .lineLimit(1)
                                if let suffix = expirySuffix(accountId: acc.id) {
                                    Text(suffix)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if model.renameDraftAccountId == acc.id {
                            iconButton(systemName: "checkmark", help: "Save name") { model.saveRenameDraft() }
                            iconButton(systemName: "xmark", help: "Dismiss") { model.cancelRenameDraft() }
                        } else {
                            if model.state.activeAccountId == acc.id {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                iconButton(systemName: "arrow.right.circle", help: "Switch to this account") {
                                    model.switchToAccount(acc.id)
                                }
                            }

                            iconButton(systemName: "trash", help: "Delete account", role: .destructive) {
                                model.deleteAccount(acc.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.state.accounts.isEmpty {
                    Spacer()
                    iconButton(systemName: "tray.and.arrow.down", help: "Sync current Codex account") {
                        model.importCurrentAccount()
                    }
                    .imageScale(.large)

                    iconButton(systemName: "person.crop.circle.badge.plus", help: "Add new account") {
                        model.startAddAccount()
                    }
                    .imageScale(.large)
                    Spacer()
                } else {
                    iconButton(systemName: "tray.and.arrow.down", help: "Sync current Codex account") {
                        model.importCurrentAccount()
                    }
                    iconButton(systemName: "person.crop.circle.badge.plus", help: "Add new account") {
                        model.startAddAccount()
                    }
                    Spacer()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            iconButton(systemName: "xmark.circle", help: "Quit") { onQuit() }
        }
    }

    private func iconButton(
        systemName: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .tooltip(help)
    }

    private func expirySuffix(accountId: String) -> String? {
        guard let exp = model.state.accessTokenExpiryByAccountId[accountId] else { return nil }

        let now = Date()
        if exp <= now { return "· Expired" }

        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let rel = fmt.localizedString(for: exp, relativeTo: now) // e.g. "in 2h"
        return "· Expires \(rel)"
    }
}
