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

/// Why a usage refresh is being requested. Menu-open refreshes may keep fresh
/// cached rows; account switches and account-set changes always start a new
/// generation so old in-flight results can never land under a changed selection.
public enum UsageRefreshTrigger: Sendable, Equatable {
    /// Menu open, window focus, or ordinary user refresh: the freshness cache
    /// applies and in-flight same-generation fetches are not duplicated.
    case menuOpen
    /// An account switch: a full all-account generation, bypassing the cache.
    case accountSwitch
    /// Accounts were added, imported, or deleted: a generation boundary, with
    /// the freshness cache applying to the rows that remain live.
    case accountSetChanged
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
    /// Rolling limit on concurrent usage requests per batch.
    static let usageConcurrencyLimit = 3

    private let lock = NSLock()
    private let engine: SwitcherooEngine
    private let fileIO: SwitcherooFileIO
    private let usageFetcher: (any AccountUsageFetching)?
    private let usageStalenessInterval: TimeInterval
    private let usageFailureCooldown: TimeInterval

    public private(set) var state: SwitcherooAppState

    /// Fired whenever an async usage result lands, so live views (the menu bar
    /// dropdown) can re-read `snapshot()` and update without waiting for the
    /// next synchronous refresh.
    public var onUsageUpdated: (@Sendable () -> Void)?

    private var usageGeneration = 0
    private var usageTask: Task<Void, Never>?
    private var usageProviderId: String?
    private var usageInFlightByAccount: [String: Int] = [:]
    private var usageLastAttemptByAccount: [String: Date] = [:]
    private var usageRetryAfterByAccount: [String: Int] = [:]

    public init(
        engine: SwitcherooEngine,
        fileIO: SwitcherooFileIO,
        providers: [ProviderDescriptor],
        usageFetcher: (any AccountUsageFetching)? = nil,
        usageStalenessInterval: TimeInterval = 60,
        usageFailureCooldown: TimeInterval = 30
    ) {
        self.engine = engine
        self.fileIO = fileIO
        self.usageFetcher = usageFetcher
        self.usageStalenessInterval = usageStalenessInterval
        self.usageFailureCooldown = usageFailureCooldown
        self.state = SwitcherooAppState(providers: providers)
    }

    deinit {
        usageTask?.cancel()
    }

    public func refresh() {
        refresh(usageTrigger: .menuOpen)
    }

    public func refresh(usageTrigger: UsageRefreshTrigger) {
        refreshAccountsMetadata()
        let accountIds = withState { $0.accounts.map(\.id) }
        refreshUsageIfNeeded(accountIds: accountIds, trigger: usageTrigger)
    }

    /// Refreshes account metadata and active status without touching usage.
    /// This is the only path the auth-sync timer may use, so background sync
    /// can never cause hidden usage requests while the menu is closed.
    private func refreshAccountsMetadata() {
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

    /// Immutable batch context captured when the generation is planned, so
    /// concurrent provider selection or account changes cannot change the
    /// credential lookup of an in-flight batch.
    private struct UsageBatchContext: Sendable {
        let providerId: String?
        let generation: Int
        let accounts: [UsageBatchAccount]
    }

    private struct UsageBatchAccount: Sendable {
        let accountId: String
        let authData: Data?
    }

    private struct UsageFetchOutcome: Sendable {
        let accountId: String
        let state: SwitcherooAccountUsageState
        let retryAfterSeconds: Int?
    }

    /// Kicks off a usage batch for all accounts when one is needed.
    ///
    /// - Every account is fetched with its own saved credential; results stay
    ///   keyed by account id so each dropdown row shows its own usage.
    /// - A bounded `.loading` state is published synchronously per account.
    /// - Repeated calls (view refresh, window focus) are cheap: accounts are
    ///   skipped while a same-generation fetch is in flight, when a fresh
    ///   result exists, or while a failed row is inside its retry cooldown.
    /// - `.accountSwitch` bypasses those guards and always starts one
    ///   all-account generation; `.accountSetChanged` always advances the
    ///   generation so a deleted account's in-flight result can never publish.
    /// - One account's failure only marks that account unavailable; the other
    ///   rows keep their own results (partial-failure isolation).
    private func refreshUsageIfNeeded(accountIds: [String], trigger: UsageRefreshTrigger) {
        guard usageFetcher != nil else {
            lock.lock()
            usageTask?.cancel()
            usageTask = nil
            usageGeneration += 1
            usageInFlightByAccount = [:]
            usageLastAttemptByAccount = [:]
            usageRetryAfterByAccount = [:]
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
            usageLastAttemptByAccount = [:]
            usageRetryAfterByAccount = [:]
            state.usageStatesByAccountId = [:]
            usageProviderId = providerId
        }

        // Prune state for accounts that no longer exist.
        let liveIds = Set(accountIds)
        state.usageStatesByAccountId = state.usageStatesByAccountId.filter { liveIds.contains($0.key) }
        usageInFlightByAccount = usageInFlightByAccount.filter { liveIds.contains($0.key) }

        let now = Date()
        var pending: [String]

        switch trigger {
        case .accountSwitch:
            // Required all-account generation for a switch: bypass the
            // freshness cache, in-flight guards, and failure cooldowns.
            pending = accountIds
            usageGeneration += 1
        case .accountSetChanged:
            // The live set changed: generation boundary even when no account
            // needs a fetch, so superseded in-flight results cannot land.
            pending = pendingAccounts(accountIds: accountIds, now: now, bypassCache: false)
            usageGeneration += 1
        case .menuOpen:
            pending = pendingAccounts(accountIds: accountIds, now: now, bypassCache: false)
            guard !pending.isEmpty else {
                lock.unlock()
                return
            }
            usageGeneration += 1
        }

        let generation = usageGeneration

        // Superseded in-flight fetches (older generation) would have their
        // results dropped; fold them into this batch so their rows resolve.
        for (accountId, inFlightGeneration) in usageInFlightByAccount where inFlightGeneration < generation {
            if case .loading = state.usageStatesByAccountId[accountId] {
                pending.append(accountId)
            }
        }
        let uniquePending = Array(Set(pending))
        guard !uniquePending.isEmpty else {
            lock.unlock()
            return
        }

        for accountId in uniquePending {
            usageInFlightByAccount[accountId] = generation
            state.usageStatesByAccountId[accountId] = .loading
        }
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            guard let self else { return }
            let context = await self.prepareBatchContext(
                accountIds: uniquePending,
                generation: generation,
                providerId: providerId
            )
            await self.fetchUsageBatch(context: context)
        }
        lock.unlock()
    }

    /// Accounts that need a fetch right now: not fresh, not inside a failure
    /// cooldown, and not already running in the current generation.
    private func pendingAccounts(accountIds: [String], now: Date, bypassCache: Bool) -> [String] {
        var pending: [String] = []
        for accountId in accountIds {
            switch state.usageStatesByAccountId[accountId] {
            case .loaded(let usage) where !bypassCache && now.timeIntervalSince(usage.fetchedAt) < usageStalenessInterval:
                continue
            case .unavailable where !bypassCache && isWithinFailureCooldown(accountId: accountId, now: now):
                continue
            default:
                break
            }
            if !bypassCache, usageInFlightByAccount[accountId] == usageGeneration {
                continue
            }
            pending.append(accountId)
        }
        return pending
    }

    private func isWithinFailureCooldown(accountId: String, now: Date) -> Bool {
        guard let lastAttempt = usageLastAttemptByAccount[accountId] else { return false }
        let retryAfter = usageRetryAfterByAccount[accountId] ?? 0
        let cooldown = max(usageFailureCooldown, TimeInterval(retryAfter))
        return now.timeIntervalSince(lastAttempt) < cooldown
    }

    /// Reads each pending account's saved credential serially into an
    /// immutable batch context. Per-account read failures become unavailable
    /// results without touching the network, and no secure store is ever
    /// entered concurrently from the network phase.
    private func prepareBatchContext(accountIds: [String], generation: Int, providerId: String?) async -> UsageBatchContext {
        var accounts: [UsageBatchAccount] = []
        for accountId in accountIds {
            let authData: Data?
            do {
                authData = try engine.accountAuthData(providerId: providerId, accountId: accountId)
            } catch {
                authData = nil
            }
            accounts.append(UsageBatchAccount(accountId: accountId, authData: authData))
        }
        return UsageBatchContext(providerId: providerId, generation: generation, accounts: accounts)
    }

    /// Runs the network phase with a small rolling concurrency limit, adding
    /// the next child only when one completes.
    private func fetchUsageBatch(context: UsageBatchContext) async {
        await withTaskGroup(of: UsageFetchOutcome.self) { group in
            var queueIndex = 0

            func startNext() {
                guard queueIndex < context.accounts.count else { return }
                let item = context.accounts[queueIndex]
                queueIndex += 1
                group.addTask {
                    await self.fetchUsageForItem(item)
                }
            }

            for _ in 0..<min(Self.usageConcurrencyLimit, context.accounts.count) {
                startNext()
            }
            for await outcome in group {
                self.publishUsage(accountId: outcome.accountId, generation: context.generation, outcome: outcome)
                startNext()
            }
        }
    }

    /// Fetches one account's usage. Failures are isolated per account and
    /// surface as that account's unavailable state only.
    private func fetchUsageForItem(_ item: UsageBatchAccount) async -> UsageFetchOutcome {
        guard let authData = item.authData else {
            return UsageFetchOutcome(
                accountId: item.accountId,
                state: .unavailable(reason: SwitcherooUsageError.noCredential.diagnosticMessage),
                retryAfterSeconds: nil
            )
        }

        recordUsageAttempt(accountId: item.accountId)
        do {
            let usage = try await usageFetcher?.fetchUsage(authData: authData, accountId: item.accountId)
            guard let usage else {
                return UsageFetchOutcome(accountId: item.accountId, state: .unavailable(reason: nil), retryAfterSeconds: nil)
            }
            return UsageFetchOutcome(accountId: item.accountId, state: .loaded(usage), retryAfterSeconds: nil)
        } catch let error as SwitcherooUsageError {
            var retryAfterSeconds: Int?
            if case .serviceUnavailable(let seconds) = error {
                retryAfterSeconds = seconds
            }
            return UsageFetchOutcome(
                accountId: item.accountId,
                state: .unavailable(reason: error.diagnosticMessage),
                retryAfterSeconds: retryAfterSeconds
            )
        } catch {
            return UsageFetchOutcome(accountId: item.accountId, state: .unavailable(reason: nil), retryAfterSeconds: nil)
        }
    }

    private func recordUsageAttempt(accountId: String) {
        lock.lock()
        usageLastAttemptByAccount[accountId] = Date()
        lock.unlock()
    }

    /// Publishes a usage result only when it still belongs to the latest
    /// batch AND the account is still live; older batches and deleted accounts
    /// are dropped. Live views are notified so the open dropdown updates.
    private func publishUsage(accountId: String, generation: Int, outcome: UsageFetchOutcome) {
        lock.lock()
        guard generation == usageGeneration else {
            lock.unlock()
            return
        }
        guard state.accounts.contains(where: { $0.id == accountId }) else {
            lock.unlock()
            return
        }
        self.state.usageStatesByAccountId[accountId] = outcome.state
        usageInFlightByAccount[accountId] = nil
        if let retryAfterSeconds = outcome.retryAfterSeconds {
            usageRetryAfterByAccount[accountId] = retryAfterSeconds
        } else {
            usageRetryAfterByAccount[accountId] = nil
        }
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
            refresh(usageTrigger: .accountSetChanged)
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
            refresh(usageTrigger: .accountSetChanged)
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
            refresh(usageTrigger: .accountSetChanged)
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
            refresh(usageTrigger: .accountSetChanged)
            return result
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            return nil
        }
    }

    public func switchToAccount(idOrName: String) throws {
        do {
            let providerId = resolveSelectedProviderId()
            _ = try? engine.syncActiveAccountSnapshot(providerId: providerId)
            try engine.switchToAccount(providerId: providerId, accountIdOrName: idOrName)
            refresh(usageTrigger: .accountSwitch)
            setReloginRequired(false)
        } catch {
            lock.lock()
            state.errorMessage = errorMessage(from: error)
            lock.unlock()
            throw error
        }
    }

    public func deleteAccount(idOrName: String) {
        do {
            let providerId = resolveSelectedProviderId()
            try engine.deleteAccount(providerId: providerId, accountIdOrName: idOrName)
            refresh(usageTrigger: .accountSetChanged)
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
            // Metadata only: the auth-sync timer path must never trigger usage
            // requests while the menu is closed.
            refreshAccountsMetadata()
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
