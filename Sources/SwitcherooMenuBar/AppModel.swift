import Foundation
import SwitcherooCore
import SwitcherooDefaultApp
import SwitcherooPresentation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: SwitcherooAppState
    @Published var renameDraftAccountId: String? = nil
    @Published var renameDraftText: String = ""
    @Published var renameDraftPlaceholder: String = ""
    @Published var statusMessage: String? = nil

    private let app: (any SwitcherooAppControlling)?
    private let timersEnabled: Bool
    private let statusMessageAutoDismissNanoseconds: UInt64
    private var pollTimer: Timer?
    private var syncTimer: Timer?
    private var statusMessageDismissTask: Task<Void, Never>?
    private static let reloginRecheckInterval: TimeInterval = 60

    init() {
        do {
            let factory = SwitcherooDefaultAppFactory()
            let app = try factory.make(loginStyle: .openTerminal)
            self.app = app
            self.state = app.snapshot()
            self.timersEnabled = true
            self.statusMessageAutoDismissNanoseconds = 3_000_000_000
            _ = app.syncActiveSnapshot()
            refresh()
            scheduleAutoSync()
        } catch {
            self.app = nil
            self.timersEnabled = false
            self.statusMessageAutoDismissNanoseconds = 3_000_000_000
            self.state = SwitcherooAppState(errorMessage: error.localizedDescription)
        }
    }

    init(
        app: any SwitcherooAppControlling,
        startTimers: Bool = false,
        statusMessageAutoDismissNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.app = app
        self.timersEnabled = startTimers
        self.statusMessageAutoDismissNanoseconds = statusMessageAutoDismissNanoseconds
        self.state = app.snapshot()
        if startTimers {
            scheduleAutoSync()
        }
    }

    deinit {
        statusMessageDismissTask?.cancel()
    }

    func refresh() {
        guard let app else { return }
        app.refresh()
        state = app.snapshot()
        if state.errorMessage != nil {
            clearStatusMessage()
        }
    }

    func startAddAccount() {
        guard let app else { return }
        clearStatusMessage()
        app.startAddAccount()
        state = app.snapshot()
        startPendingPoll()
    }

    func importCurrentAccount() {
        guard let app else { return }
        let result = app.importCurrentAccount(setActiveIfFirst: true)
        if let result {
            handleAccountWriteResult(result, createdMessage: "Imported account.")
        } else {
            clearStatusMessage()
        }
        state = app.snapshot()
        scheduleAutoSync()
    }

    func switchToAccount(_ accountId: String) {
        guard let app else { return }
        clearStatusMessage()
        app.switchToAccount(idOrName: accountId)
        state = app.snapshot()
        scheduleAutoSync()
    }

    func deleteAccount(_ accountId: String) {
        guard let app else { return }
        clearStatusMessage()
        app.deleteAccount(idOrName: accountId)
        state = app.snapshot()
    }

    func finalizePendingIfReady(setActive: Bool) {
        guard let app else { return }
        let result = app.finalizePendingIfReady(setActiveIfFirst: true)
        if result == nil {
            // For legacy call sites (CLI-style), still support explicit setActive.
            _ = app.finalizePendingIfReady(setActive: setActive)
        }
        if let result {
            handleAccountWriteResult(result, createdMessage: "Added account.")
        } else {
            clearStatusMessage()
        }
        let next = app.snapshot()
        state = next
        scheduleAutoSync()
        if next.pendingLogin == nil {
            stopPendingPoll()
        }
    }

    func syncActiveSnapshot() {
        guard let app else { return }
        _ = app.syncActiveSnapshot()
        state = app.snapshot()
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

    private func handleAccountWriteResult(_ result: SwitcherooAccountWriteResult, createdMessage: String) {
        switch result.disposition {
        case .created:
            if let acc = result.account {
                beginRenameDraft(accountId: acc.id, placeholder: acc.name)
            }
            publishStatusMessage(createdMessage)
        case .updatedExisting:
            let name = result.account?.name ?? "account"
            publishStatusMessage("Refreshed \(name).")
        case .skippedUnmatchedIdentity:
            publishStatusMessage("No matching account to refresh.")
        }
    }

    private func publishStatusMessage(_ message: String) {
        statusMessageDismissTask?.cancel()
        statusMessage = message

        let delay = statusMessageAutoDismissNanoseconds
        statusMessageDismissTask = Task { [weak self, message] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            await MainActor.run {
                guard self?.statusMessage == message else { return }
                self?.statusMessage = nil
                self?.statusMessageDismissTask = nil
            }
        }
    }

    private func clearStatusMessage() {
        statusMessageDismissTask?.cancel()
        statusMessageDismissTask = nil
        statusMessage = nil
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

    private func scheduleAutoSync() {
        guard timersEnabled else { return }
        syncTimer?.invalidate()
        guard let app else { return }

        let decision = app.autoSyncDecision(now: Date())
        state = app.snapshot()

        switch decision {
        case .poll(let interval):
            syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.syncActiveSnapshot()
                    self?.scheduleAutoSync()
                }
            }
        case .recheck(let interval):
            syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleAutoSync()
                }
            }
        case .disabled(let requiresRelogin):
            if requiresRelogin {
                // Keep a low-frequency recheck running so a user login can clear the banner without
                // requiring an explicit UI action, but avoid tight polling in a broken state.
                syncTimer = Timer.scheduledTimer(withTimeInterval: Self.reloginRecheckInterval, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleAutoSync()
                    }
                }
            } else {
                syncTimer = nil
            }
        }
    }
}
