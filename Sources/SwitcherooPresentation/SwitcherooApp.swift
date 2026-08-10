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
    public var usageStatesByAccountId: [String: SwitcherooAccountUsageState]
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
        usageStatesByAccountId: [String: SwitcherooAccountUsageState] = [:],
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
        self.usageStatesByAccountId = usageStatesByAccountId
        self.requiresRelogin = requiresRelogin
        self.pendingLogin = pendingLogin
        self.pendingHint = pendingHint
    }
}

public final class SwitcherooApp: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: SwitcherooEngine
    private let fileIO: SwitcherooFileIO
    private let usageFetcher: (any AccountUsageFetching)?
    private let usageStalenessInterval: TimeInterval

    public private(set) var state: SwitcherooAppState

    /// Fired whenever an async usage result lands, so live views (the menu bar
    /// dropdown) can re-read `snapshot()` and update without waiting for the
    /// next synchronous refresh.
    public var onUsageUpdated: (@Sendable () -> Void)?

    private var usageGeneration = 0
    private var usageTask: Task<Void, Never>?
    private var usageProviderId: String?
    private var usageInFlightByAccount: [String: Int] = [:]

    public init(
        engine: SwitcherooEngine,
        fileIO: SwitcherooFileIO,
        providers: [ProviderDescriptor],
        usageFetcher: (any AccountUsageFetching)? = nil,
        usageStalenessInterval: TimeInterval = 60
    ) {
        self.engine = engine
        self.fileIO = fileIO
        self.usageFetcher = usageFetcher
        self.usageStalenessInterval = usageStalenessInterval
        self.state = SwitcherooAppState(providers: providers)
    }

    deinit {
        usageTask?.cancel()
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

            refreshUsageIfNeeded(accountIds: accounts.map(\.id))
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
        }
    }

    /// Kicks off a usage batch for all accounts when one is needed.
    ///
    /// - Every account is fetched with its own saved credential; results stay
    ///   keyed by account id so each dropdown row shows its own usage.
    /// - A bounded `.loading` state is published synchronously per account.
    /// - Repeated calls (view refresh, window focus) are cheap: accounts are
    ///   skipped while a same-generation fetch is in flight or when a fresh
    ///   result already exists.
    /// - Starting a batch bumps the generation, cancels the previous batch, and
    ///   folds any still-loading accounts into the new batch, so a slower older
    ///   response can never overwrite a newer batch (latest-request-wins) and
    ///   a loading row always resolves.
    /// - One account's failure only marks that account unavailable; the other
    ///   rows keep their own results (partial-failure isolation).
    private func refreshUsageIfNeeded(accountIds: [String]) {
        guard usageFetcher != nil else {
            lock.lock()
            usageTask?.cancel()
            usageTask = nil
            usageGeneration += 1
            usageInFlightByAccount = [:]
            state.usageStatesByAccountId = [:]
            usageProviderId = nil
            lock.unlock()
            return
        }

        let providerId = resolveSelectedProviderId()

        lock.lock()
        if usageProviderId != providerId {
            // Provider switch: everything from the previous provider is stale.
            usageTask?.cancel()
            usageGeneration += 1
            usageInFlightByAccount = [:]
            state.usageStatesByAccountId = [:]
            usageProviderId = providerId
        }

        // Prune state for accounts that no longer exist.
        let liveIds = Set(accountIds)
        state.usageStatesByAccountId = state.usageStatesByAccountId.filter { liveIds.contains($0.key) }
        usageInFlightByAccount = usageInFlightByAccount.filter { liveIds.contains($0.key) }

        let now = Date()
        var pending: [String] = []
        for accountId in accountIds {
            switch state.usageStatesByAccountId[accountId] {
            case .loaded(let usage) where now.timeIntervalSince(usage.fetchedAt) < usageStalenessInterval:
                continue
            default:
                break
            }
            if usageInFlightByAccount[accountId] == usageGeneration {
                // A fetch for the current generation is already running.
                continue
            }
            pending.append(accountId)
        }

        guard !pending.isEmpty else {
            lock.unlock()
            return
        }

        usageGeneration += 1
        let generation = usageGeneration

        // Superseded in-flight fetches (older generation) would have their
        // results dropped; fold them into this batch so their rows resolve.
        for (accountId, inFlightGeneration) in usageInFlightByAccount where inFlightGeneration < generation {
            if case .loading = state.usageStatesByAccountId[accountId] {
                pending.append(accountId)
            }
        }
        let uniquePending = Array(Set(pending))

        for accountId in uniquePending {
            usageInFlightByAccount[accountId] = generation
            state.usageStatesByAccountId[accountId] = .loading
        }
        usageTask?.cancel()
        lock.unlock()

        usageTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchUsageBatch(accountIds: uniquePending, generation: generation)
        }
    }

    /// Fetches one account's usage. Failures are isolated per account and
    /// surface as that account's unavailable state only.
    private func fetchUsage(accountId: String) async -> SwitcherooAccountUsageState {
        do {
            let providerId = resolveSelectedProviderId()
            let authData = try engine.accountAuthData(providerId: providerId, accountId: accountId)
            let usage = try await usageFetcher?.fetchUsage(authData: authData, accountId: accountId)
            guard let usage else { return .unavailable(reason: nil) }
            return .loaded(usage)
        } catch let error as SwitcherooUsageError {
            return .unavailable(reason: error.diagnosticMessage)
        } catch {
            return .unavailable(reason: errorMessage(from: error))
        }
    }

    private func fetchUsageBatch(accountIds: [String], generation: Int) async {
        await withTaskGroup(of: (String, SwitcherooAccountUsageState).self) { group in
            for accountId in accountIds {
                group.addTask { [weak self] in
                    guard let self else { return (accountId, .unavailable(reason: nil)) }
                    let state = await self.fetchUsage(accountId: accountId)
                    return (accountId, state)
                }
            }
            for await (accountId, state) in group {
                self.publishUsage(accountId: accountId, generation: generation, state: state)
            }
        }
    }

    /// Publishes a usage result only when it still belongs to the latest
    /// batch; older responses are dropped. Live views are notified so the open
    /// dropdown updates in place.
    private func publishUsage(accountId: String, generation: Int, state: SwitcherooAccountUsageState) {
        lock.lock()
        guard generation == usageGeneration else {
            lock.unlock()
            return
        }
        self.state.usageStatesByAccountId[accountId] = state
        usageInFlightByAccount[accountId] = nil
        lock.unlock()
        onUsageUpdated?()
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
