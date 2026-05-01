import SwiftUI
import SwitcherooCore

struct StatusView: View {
    @ObservedObject var model: AppModel
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Active: \(model.statusText)")
                .font(.subheadline)

            accountList

            Divider()

            addSection

            if let hint = model.pendingHint {
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
            Button("Refresh") { model.refresh() }
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accounts")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.accounts.isEmpty {
                Text("No accounts added yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts) { acc in
                    HStack(spacing: 8) {
                        Text(acc.name)
                            .lineLimit(1)
                        Spacer()
                        if model.activeAccountId == acc.id {
                            Text("Active")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Switch") { model.switchToAccount(acc) }
                        }
                        Button("Delete", role: .destructive) { model.deleteAccount(acc) }
                    }
                }
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Account")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Account name", text: $model.newAccountName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Login in Terminal") { model.startAddAccount() }
                    .disabled(model.newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Import Current") { model.importCurrentAccount() }
                    .disabled(model.newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
    }

    private var footer: some View {
            HStack {
                Button("Sync Now") { model.syncActiveSnapshot() }
                Spacer()
            Button("Quit") { onQuit() }
        }
    }
}
