import Foundation
import SwitcherooCore

public struct ProviderDescriptor: Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct SwitcherooAppState: Sendable {
    public var errorMessage: String?
    public var providers: [ProviderDescriptor]
    public var selectedProviderId: String?

    public var accounts: [SwitcherooAccount]
    public var activeAccountId: String?
    public var statusText: String
    public var accessTokenExpiryByAccountId: [String: Date]

    public var pendingLogin: PendingLogin?
    public var pendingHint: String?

    public init(
        errorMessage: String? = nil,
        providers: [ProviderDescriptor] = [],
        selectedProviderId: String? = nil,
        accounts: [SwitcherooAccount] = [],
        activeAccountId: String? = nil,
        statusText: String = "No active account",
        accessTokenExpiryByAccountId: [String: Date] = [:],
        pendingLogin: PendingLogin? = nil,
        pendingHint: String? = nil
    ) {
        self.errorMessage = errorMessage
        self.providers = providers
        self.selectedProviderId = selectedProviderId
        self.accounts = accounts
        self.activeAccountId = activeAccountId
        self.statusText = statusText
        self.accessTokenExpiryByAccountId = accessTokenExpiryByAccountId
        self.pendingLogin = pendingLogin
        self.pendingHint = pendingHint
    }
}

public final class SwitcherooApp: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: SwitcherooEngine
    private let fileIO: SwitcherooFileIO

    public private(set) var state: SwitcherooAppState

    public init(engine: SwitcherooEngine, fileIO: SwitcherooFileIO, providers: [ProviderDescriptor]) {
        self.engine = engine
        self.fileIO = fileIO
        self.state = SwitcherooAppState(providers: providers)
    }

    public func refresh() {
        do {
            let providerId = resolveSelectedProviderId()
            let accounts = try engine.listAccounts(providerId: providerId)
            let activeId = try engine.activeAccount(providerId: providerId)?.id
            let expiryById = (try? engine.accessTokenExpiryByAccountId(providerId: providerId)) ?? [:]

            let statusText = activeId.flatMap { id in
                accounts.first(where: { $0.id == id })?.name
            } ?? "No active account"

            lock.lock()
            state.errorMessage = nil
            state.accounts = accounts
            state.activeAccountId = activeId
            state.statusText = statusText
            state.accessTokenExpiryByAccountId = expiryById
            lock.unlock()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func snapshot() -> SwitcherooAppState {
        withState { $0 }
    }

    public func selectProvider(_ providerId: String?) {
        lock.lock()
        state.selectedProviderId = providerId
        lock.unlock()
        refresh()
    }

    public func startAddAccount(name: String) {
        do {
            let providerId = resolveSelectedProviderId()
            let pending = try engine.startAddAccount(providerId: providerId, name: name)

            lock.lock()
            state.pendingLogin = pending
            state.pendingHint = "Complete login, then Switcheroo will import it."
            lock.unlock()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func startAddAccount() {
        do {
            let providerId = resolveSelectedProviderId()
            let pending = try engine.startAddAccount(providerId: providerId)

            lock.lock()
            state.pendingLogin = pending
            state.pendingHint = "Complete login, then Switcheroo will import it."
            lock.unlock()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func importCurrentAccount(name: String) {
        do {
            let providerId = resolveSelectedProviderId()
            _ = try engine.importCurrentAccount(providerId: providerId, name: name, setActive: false)
            refresh()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    @discardableResult
    public func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccount? {
        do {
            let providerId = resolveSelectedProviderId()
            let acc = try engine.importCurrentAccountWithDerivedName(providerId: providerId, setActiveIfFirst: setActiveIfFirst)
            refresh()
            return acc
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    public func finalizePendingIfReady(setActive: Bool) {
        guard let pending = withState({ $0.pendingLogin }) else { return }
        guard fileIO.fileExists(path: pending.expectedAuthFilePath) else { return }

        do {
            try engine.finalizeAddAccount(pending, setActive: setActive)
            lock.lock()
            state.pendingLogin = nil
            state.pendingHint = nil
            lock.unlock()
            refresh()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccount? {
        guard let pending = withState({ $0.pendingLogin }) else { return nil }
        guard fileIO.fileExists(path: pending.expectedAuthFilePath) else { return nil }

        do {
            let acc = try engine.finalizeAddAccountWithDerivedName(pending, setActiveIfFirst: setActiveIfFirst)
            lock.lock()
            state.pendingLogin = nil
            state.pendingHint = nil
            lock.unlock()
            refresh()
            return acc
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    public func switchToAccount(idOrName: String) {
        do {
            let providerId = resolveSelectedProviderId()
            try engine.switchToAccount(providerId: providerId, accountIdOrName: idOrName)
            refresh()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func deleteAccount(idOrName: String) {
        do {
            let providerId = resolveSelectedProviderId()
            try engine.deleteAccount(providerId: providerId, accountIdOrName: idOrName)
            refresh()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func syncActiveSnapshot() {
        do {
            let providerId = resolveSelectedProviderId()
            _ = try engine.syncActiveAccountSnapshotIfNeeded(providerId: providerId)
        } catch {
            // Best-effort; ignore.
        }
    }

    public func renameAccount(accountId: String, newName: String) {
        do {
            let providerId = resolveSelectedProviderId()
            try engine.renameAccount(providerId: providerId, accountId: accountId, newName: newName)
            refresh()
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    public func shouldShowProviderUI() -> Bool {
        withState { $0.providers.count > 1 }
    }

    private func resolveSelectedProviderId() -> String? {
        let selected = withState { $0.selectedProviderId }
        if let selected, !selected.isEmpty { return selected }
        let providers = withState { $0.providers }
        if providers.count == 1 { return providers.first?.id }
        return nil
    }

    private func withState<T>(_ body: (SwitcherooAppState) -> T) -> T {
        lock.lock()
        let snap = state
        lock.unlock()
        return body(snap)
    }

    private func errorMessage(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
