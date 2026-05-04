import Foundation
import SwitcherooDefaultApp
import SwitcherooPresentation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: SwitcherooAppState
    @Published var renameDraftAccountId: String? = nil
    @Published var renameDraftText: String = ""
    @Published var renameDraftPlaceholder: String = ""

    private let app: (any SwitcherooAppControlling)?
    private let timersEnabled: Bool
    private var pollTimer: Timer?
    private var syncTimer: Timer?

    init() {
        do {
            let factory = SwitcherooDefaultAppFactory()
            let app = try factory.make(loginStyle: .openTerminal)
            self.app = app
            self.state = app.snapshot()
            self.timersEnabled = true
            refresh()
            startBackgroundSync()
        } catch {
            self.app = nil
            self.timersEnabled = false
            self.state = SwitcherooAppState(errorMessage: error.localizedDescription)
        }
    }

    init(app: any SwitcherooAppControlling, startTimers: Bool = false) {
        self.app = app
        self.timersEnabled = startTimers
        self.state = app.snapshot()
        if startTimers {
            startBackgroundSync()
        }
    }

    func refresh() {
        guard let app else { return }
        app.refresh()
        state = app.snapshot()
    }

    func startAddAccount() {
        guard let app else { return }
        app.startAddAccount()
        state = app.snapshot()
        startPendingPoll()
    }

    func importCurrentAccount() {
        guard let app else { return }
        if let acc = app.importCurrentAccount(setActiveIfFirst: true) {
            beginRenameDraft(accountId: acc.id, placeholder: acc.name)
        }
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
        if let acc = app.finalizePendingIfReady(setActiveIfFirst: true) {
            beginRenameDraft(accountId: acc.id, placeholder: acc.name)
        } else {
            // For legacy call sites (CLI-style), still support explicit setActive.
            app.finalizePendingIfReady(setActive: setActive)
        }
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

    func cancelRenameDraft() {
        renameDraftAccountId = nil
        renameDraftText = ""
        renameDraftPlaceholder = ""
    }

    func startRenameDraft(accountId: String, currentName: String) {
        renameDraftAccountId = accountId
        renameDraftText = currentName
        renameDraftPlaceholder = currentName
    }

    func saveRenameDraft() {
        guard let app else { return }
        guard let accountId = renameDraftAccountId else { return }

        let typed = renameDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? renameDraftPlaceholder : typed
        guard !name.isEmpty else { return }

        app.renameAccount(accountId: accountId, newName: name)
        cancelRenameDraft()
        state = app.snapshot()
    }

    private func beginRenameDraft(accountId: String, placeholder: String) {
        renameDraftAccountId = accountId
        renameDraftText = ""
        renameDraftPlaceholder = placeholder
    }

    private func startPendingPoll() {
        guard timersEnabled else { return }
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
        guard timersEnabled else { return }
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncActiveSnapshot()
            }
        }
    }
}
