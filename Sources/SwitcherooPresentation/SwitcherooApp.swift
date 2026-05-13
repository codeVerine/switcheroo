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
    public var accountMetadataById: [String: SwitcherooAccountMetadata]
    public var requiresRelogin: Bool

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
        accountMetadataById: [String: SwitcherooAccountMetadata] = [:],
        requiresRelogin: Bool = false,
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
        self.accountMetadataById = accountMetadataById
        self.requiresRelogin = requiresRelogin
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
            let metadataById = (try? engine.metadataByAccountId(providerId: providerId)) ?? [:]
            let expiryById = metadataById.compactMapValues(\.accessTokenExpiry)

            let statusText = activeId.flatMap { id in
                accounts.first(where: { $0.id == id })?.name
            } ?? "No active account"

            lock.lock()
            state.errorMessage = nil
            state.accounts = accounts
            state.activeAccountId = activeId
            state.statusText = statusText
            state.accessTokenExpiryByAccountId = expiryById
            state.accountMetadataById = metadataById
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

    @discardableResult
    public func importCurrentAccount(name: String) -> SwitcherooAccountWriteResult? {
        do {
            let providerId = resolveSelectedProviderId()
            let result = try engine.importCurrentAccount(providerId: providerId, name: name, setActive: false)
            refresh()
            return result
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    @discardableResult
    public func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult? {
        do {
            let providerId = resolveSelectedProviderId()
            let result = try engine.importCurrentAccountWithDerivedName(providerId: providerId, setActiveIfFirst: setActiveIfFirst)
            refresh()
            return result
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    @discardableResult
    public func finalizePendingIfReady(setActive: Bool) -> SwitcherooAccountWriteResult? {
        guard let pending = withState({ $0.pendingLogin }) else { return nil }
        guard fileIO.fileExists(path: pending.expectedAuthFilePath) else { return nil }

        do {
            let result = try engine.finalizeAddAccount(pending, setActive: setActive)
            lock.lock()
            state.pendingLogin = nil
            state.pendingHint = nil
            lock.unlock()
            refresh()
            return result
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    @discardableResult
    public func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult? {
        guard let pending = withState({ $0.pendingLogin }) else { return nil }
        guard fileIO.fileExists(path: pending.expectedAuthFilePath) else { return nil }

        do {
            let result = try engine.finalizeAddAccountWithDerivedName(pending, setActiveIfFirst: setActiveIfFirst)
            lock.lock()
            state.pendingLogin = nil
            state.pendingHint = nil
            lock.unlock()
            refresh()
            return result
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
            _ = try? engine.syncActiveAccountSnapshot(providerId: providerId)
            try engine.switchToAccount(providerId: providerId, accountIdOrName: idOrName)
            refresh()
            setReloginRequired(false)
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

    @discardableResult
    public func syncActiveSnapshot() -> SwitcherooActiveSnapshotSyncResult? {
        do {
            let providerId = resolveSelectedProviderId()
            let result = try engine.syncActiveAccountSnapshot(providerId: providerId)
            refresh()
            setReloginRequired(result.requiresRelogin && shouldWarnAboutRelogin())
            return result
        } catch {
            setReloginRequired(shouldWarnAboutRelogin())
            return nil
        }
    }

    public func autoSyncDecision(now: Date) -> SwitcherooAutoSyncDecision {
        guard shouldWarnAboutRelogin() else {
            setReloginRequired(false)
            return .disabled(requiresRelogin: false)
        }

        do {
            let providerId = resolveSelectedProviderId()
            let accounts = try engine.listAccounts(providerId: providerId)
            let authInfo = try engine.activeAuthInfo(providerId: providerId)

            // Avoid Keychain reads here. If we can’t confidently match the active auth identity to an existing
            // configured account identity, don’t poll aggressively in the background.
            if accounts.allSatisfy({ $0.identityKey != nil }) {
                guard let identityKey = authInfo.identityKey else {
                    setReloginRequired(true)
                    return .disabled(requiresRelogin: true)
                }
                if !accounts.contains(where: { $0.identityKey == identityKey }) {
                    setReloginRequired(true)
                    return .disabled(requiresRelogin: true)
                }
            }

            let decision = SwitcherooAutoSyncPolicy.decision(accessTokenExpiry: authInfo.accessTokenExpiry, now: now)
            setReloginRequired(decision.requiresRelogin)
            return decision
        } catch {
            let requiresRelogin = shouldWarnAboutRelogin()
            setReloginRequired(requiresRelogin)
            return .disabled(requiresRelogin: requiresRelogin)
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

    private func shouldWarnAboutRelogin() -> Bool {
        withState { state in
            guard let activeAccountId = state.activeAccountId else { return false }
            return state.accounts.contains(where: { $0.id == activeAccountId })
        }
    }

    private func setReloginRequired(_ required: Bool) {
        lock.lock()
        state.requiresRelogin = required
        lock.unlock()
    }

    private func errorMessage(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
