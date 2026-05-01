import Foundation
import SwitcherooDefaultApp
import SwitcherooPresentation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: SwitcherooAppState
    @Published var newAccountName: String = ""

    private let app: SwitcherooApp?
    private var pollTimer: Timer?
    private var syncTimer: Timer?

    init() {
        do {
            let factory = SwitcherooDefaultAppFactory()
            self.app = try factory.make(loginStyle: .openTerminal)
            self.state = self.app?.snapshot() ?? SwitcherooAppState()
            refresh()
            startBackgroundSync()
        } catch {
            self.app = nil
            self.state = SwitcherooAppState(errorMessage: error.localizedDescription)
        }
    }

    func refresh() {
        guard let app else { return }
        app.refresh()
        state = app.snapshot()
    }

    func startAddAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let app else { return }
        app.startAddAccount(name: name)
        newAccountName = ""
        state = app.snapshot()
        startPendingPoll()
    }

    func importCurrentAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let app else { return }
        app.importCurrentAccount(name: name)
        newAccountName = ""
        state = app.snapshot()
    }

    func switchToAccount(_ accountId: String) {
        guard let app else { return }
        app.switchToAccount(idOrName: accountId)
        state = app.snapshot()
    }

    func deleteAccount(_ accountId: String) {
        guard let app else { return }
        app.deleteAccount(idOrName: accountId)
        state = app.snapshot()
    }

    func finalizePendingIfReady(setActive: Bool) {
        guard let app else { return }
        app.finalizePendingIfReady(setActive: setActive)
        let next = app.snapshot()
        state = next
        if next.pendingLogin == nil {
            stopPendingPoll()
        }
    }

    func syncActiveSnapshot() {
        guard let app else { return }
        app.syncActiveSnapshot()
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
