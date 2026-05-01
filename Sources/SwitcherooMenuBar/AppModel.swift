import Foundation
import SwitcherooCore

@MainActor
final class AppModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var accounts: [SwitcherooAccount] = []
    @Published var activeAccountId: String?
    @Published var statusText: String = ""

    @Published var newAccountName: String = ""
    @Published var pendingLogin: PendingLogin?
    @Published var pendingHint: String?

    private let service: SwitcherooService?
    private var pollTimer: Timer?
    private var syncTimer: Timer?

    init() {
        do {
            self.service = try SwitcherooService()
            refresh()
            startBackgroundSync()
        } catch {
            self.service = nil
            self.errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        guard let service else { return }
        accounts = service.listAccounts()
        activeAccountId = service.activeAccount()?.id
        statusText = activeAccountId.flatMap { id in accounts.first(where: { $0.id == id })?.name } ?? "No active account"
    }

    func startAddAccount() {
        guard let service else { return }
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            let pending = try service.startAddAccount(name: name)
            pendingLogin = pending
            pendingHint = "Complete login in Terminal, then Switcheroo will import it."
            newAccountName = ""
            startPendingPoll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importCurrentAccount() {
        guard let service else { return }
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try service.importCurrentAccount(name: name, setActive: false)
            newAccountName = ""
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchToAccount(_ account: SwitcherooAccount) {
        guard let service else { return }
        do {
            try service.switchToAccount(accountId: account.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAccount(_ account: SwitcherooAccount) {
        guard let service else { return }
        do {
            try service.deleteAccount(accountId: account.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func finalizePendingIfReady(setActive: Bool) {
        guard let service else { return }
        guard let pendingLogin else { return }
        guard FileManager.default.fileExists(atPath: pendingLogin.expectedAuthJSONPath) else { return }

        do {
            try service.finalizeAddAccount(pendingLogin, setActive: setActive)
            self.pendingLogin = nil
            self.pendingHint = nil
            stopPendingPoll()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncActiveSnapshot() {
        guard let service else { return }
        do {
            _ = try service.syncActiveAccountSnapshotIfNeeded()
        } catch {
            // Best-effort; show only if user is interacting.
        }
    }

    private func startPendingPoll() {
        stopPendingPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.finalizePendingIfReady(setActive: false)
            }
        }
    }

    private func stopPendingPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startBackgroundSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncActiveSnapshot()
            }
        }
    }
}

