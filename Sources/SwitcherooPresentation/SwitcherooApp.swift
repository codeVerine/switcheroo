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

/// Why a refresh is being requested. Opening the menu renders cached usage and
/// never fetches; account switches and account-set changes always start a new
/// generation so old in-flight results can never land under a changed selection.
public enum UsageRefreshTrigger: Sendable, Equatable {
    /// Menu open, window focus, or ordinary user refresh: metadata-only. The
    /// cached per-account usage rows are rendered as-is and no usage request
    /// is ever initiated from this trigger.
    case menuOpen
    /// App launch: one all-account seeding generation so the cache is populated
    /// immediately, bypassing the freshness cache (nothing is cached yet).
    case launch
    /// An account switch: a full all-account generation, bypassing the cache.
    case accountSwitch
    /// Accounts were added, imported, or deleted: a generation boundary, with
    /// the freshness cache applying to the rows that remain live.
    case accountSetChanged
    /// Background tiered timer: refresh the active account when its result is
    /// older than the active tier interval (5 minutes) and inactive accounts
    /// when older than the inactive tier interval (30 minutes).
    case tieredTimer
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
    /// Rolling limit on concurrent usage requests per batch. Superseded
    /// batches can run their own limited window while a newer batch starts;
    /// the generation guard still drops every stale result.
    static let usageConcurrencyLimit = 3

    private let lock = NSLock()
    private let engine: SwitcherooEngine
    private let fileIO: SwitcherooFileIO
    private let usageFetcher: (any AccountUsageFetching)?
    /// How old a loaded result may be before the active account is refreshed
    /// by the tiered timer (5 minutes).
    private let usageActiveRefreshInterval: TimeInterval
    /// How old a loaded result may be before an inactive account is refreshed
    /// by the tiered timer (30 minutes).
    private let usageInactiveRefreshInterval: TimeInterval
    private let usageFailureCooldown: TimeInterval
    private let clock: @Sendable () -> Date

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
    private var usageFailureCountByAccount: [String: Int] = [:]

    public init(
        engine: SwitcherooEngine,
        fileIO: SwitcherooFileIO,
        providers: [ProviderDescriptor],
        usageFetcher: (any AccountUsageFetching)? = nil,
        usageActiveRefreshInterval: TimeInterval = 300,
        usageInactiveRefreshInterval: TimeInterval = 1800,
        usageFailureCooldown: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.fileIO = fileIO
        self.usageFetcher = usageFetcher
        self.usageActiveRefreshInterval = usageActiveRefreshInterval
        self.usageInactiveRefreshInterval = usageInactiveRefreshInterval
        self.usageFailureCooldown = usageFailureCooldown
        self.clock = clock
        self.state = SwitcherooAppState(providers: providers)
    }

    /// Compatibility spelling for callers that use the usage feature's
    /// original injectable-clock label.
    public convenience init(
        engine: SwitcherooEngine,
        fileIO: SwitcherooFileIO,
        providers: [ProviderDescriptor],
        usageFetcher: (any AccountUsageFetching)? = nil,
        usageActiveRefreshInterval: TimeInterval = 300,
        usageInactiveRefreshInterval: TimeInterval = 1800,
        usageFailureCooldown: TimeInterval = 30,
        now: @escaping @Sendable () -> Date
    ) {
        self.init(
            engine: engine,
            fileIO: fileIO,
            providers: providers,
            usageFetcher: usageFetcher,
            usageActiveRefreshInterval: usageActiveRefreshInterval,
            usageInactiveRefreshInterval: usageInactiveRefreshInterval,
            usageFailureCooldown: usageFailureCooldown,
            clock: now
        )
    }

    deinit {
        usageTask?.cancel()
    }

    /// Metadata-only refresh (menu-open semantics): reloads account metadata
    /// and renders the cached usage rows without ever fetching usage.
    public func refresh() {
        refresh(usageTrigger: .menuOpen)
    }

    public func refresh(usageTrigger: UsageRefreshTrigger) {
        refreshAccountsMetadata()
        guard usageTrigger != .menuOpen else {
            // Opening the menu renders the current cached usage state; it must
            // never itself initiate usage fetching.
            return
        }
        let accountIds = withState { $0.accounts.map(\.id) }
        let activeAccountId = withState { $0.activeAccountId }
        refreshUsageIfNeeded(accountIds: accountIds, activeAccountId: activeAccountId, trigger: usageTrigger)
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
    /// - Repeated timer ticks are cheap: accounts are skipped while a
    ///   same-generation fetch is in flight, when their tier interval has not
    ///   elapsed, or while a failed row is inside its retry cooldown.
    /// - `.launch` and `.accountSwitch` bypass those guards and always start
    ///   one all-account generation; `.accountSetChanged` and `.tieredTimer`
    ///   apply the tiered freshness rules, and both always advance the
    ///   generation so a deleted or superseded account's result can never
    ///   publish.
    /// - `.menuOpen` never fetches: it is handled before the batch is planned.
    /// - One account's failure only marks that account unavailable; the other
    ///   rows keep their own results (partial-failure isolation).
    private func refreshUsageIfNeeded(accountIds: [String], activeAccountId: String?, trigger: UsageRefreshTrigger) {
        guard usageFetcher != nil else {
            lock.lock()
            usageTask?.cancel()
            usageTask = nil
            usageGeneration += 1
            usageInFlightByAccount = [:]
            usageLastAttemptByAccount = [:]
            usageRetryAfterByAccount = [:]
            usageFailureCountByAccount = [:]
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
            usageFailureCountByAccount = [:]
            state.usageStatesByAccountId = [:]
            usageProviderId = providerId
        }

        // Prune state for accounts that no longer exist, including cooldown
        // bookkeeping so deleted accounts retain nothing.
        let liveIds = Set(accountIds)
        state.usageStatesByAccountId = state.usageStatesByAccountId.filter { liveIds.contains($0.key) }
        usageInFlightByAccount = usageInFlightByAccount.filter { liveIds.contains($0.key) }
        usageLastAttemptByAccount = usageLastAttemptByAccount.filter { liveIds.contains($0.key) }
        usageRetryAfterByAccount = usageRetryAfterByAccount.filter { liveIds.contains($0.key) }
        usageFailureCountByAccount = usageFailureCountByAccount.filter { liveIds.contains($0.key) }

        let currentTime = clock()
        var pending: [String]

        switch trigger {
        case .menuOpen:
            // Defensive: `refresh(usageTrigger:)` routes menu-open to a
            // metadata-only refresh, so this case is unreachable. A menu-open
            // trigger must never fetch.
            lock.unlock()
            return
        case .launch, .accountSwitch:
            // Required all-account generation for launch seeding and account
            // switches: bypass the freshness cache, in-flight guards, and
            // failure cooldowns. The active account is ordered first so its
            // row resolves first.
            if let activeAccountId, accountIds.contains(activeAccountId) {
                pending = [activeAccountId] + accountIds.filter { $0 != activeAccountId }
            } else {
                pending = accountIds
            }
            usageGeneration += 1
        case .accountSetChanged:
            // The live set changed: generation boundary even when no account
            // needs a fetch, so superseded in-flight results cannot land.
            usageTask?.cancel()
            usageTask = nil
            pending = pendingAccounts(accountIds: accountIds, activeAccountId: activeAccountId, now: currentTime, bypassCache: false)
            usageGeneration += 1
        case .tieredTimer:
            // Background tiered refresh: only accounts whose tier interval has
            // elapsed are due. When nothing is due, leave the current
            // generation untouched so in-flight results can still land.
            pending = pendingAccounts(accountIds: accountIds, activeAccountId: activeAccountId, now: currentTime, bypassCache: false)
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
        // Deduplicate while preserving account order so the first rows to
        // fetch are deterministic (the active account first on switch).
        var seen = Set<String>()
        let uniquePending = pending.filter { seen.insert($0).inserted }
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
            guard !Task.isCancelled else { return }
            await self.fetchUsageBatch(context: context)
        }
        lock.unlock()
    }

    /// Accounts that need a fetch right now: the active account when its loaded
    /// result is older than the active tier interval, inactive accounts when
    /// older than the inactive tier interval; never inside a failure cooldown;
    /// never already running in the current generation.
    private func pendingAccounts(accountIds: [String], activeAccountId: String?, now: Date, bypassCache: Bool) -> [String] {
        var pending: [String] = []
        for accountId in accountIds {
            let tierInterval = (accountId == activeAccountId)
                ? usageActiveRefreshInterval
                : usageInactiveRefreshInterval
            switch state.usageStatesByAccountId[accountId] {
            case .loaded(let usage) where !bypassCache && now.timeIntervalSince(usage.fetchedAt) < tierInterval:
                continue
            case .unavailable where !bypassCache && isWithinFailureCooldown(accountId: accountId, now: now, isActive: accountId == activeAccountId):
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

    /// Returns true when the account is still inside its failure cooldown
    /// window. Active accounts use a flat 30-second cooldown for fast
    /// recovery; inactive accounts use per-account exponential backoff
    /// (1, 2, 4, 8, 16 min, capped at 30 min) reset after each success.
    /// A server Retry-After header is always honoured when longer.
    private func isWithinFailureCooldown(accountId: String, now: Date, isActive: Bool) -> Bool {
        guard let lastAttempt = usageLastAttemptByAccount[accountId] else { return false }
        let retryAfter = usageRetryAfterByAccount[accountId] ?? 0
        let baseCooldown: TimeInterval
        if isActive {
            baseCooldown = usageFailureCooldown
        } else {
            let failureCount = usageFailureCountByAccount[accountId] ?? 0
            if failureCount > 0 {
                let backoffMinutes: [TimeInterval] = [60, 120, 240, 480, 960, 1800]
                let index = min(failureCount - 1, backoffMinutes.count - 1)
                baseCooldown = backoffMinutes[index]
            } else {
                baseCooldown = usageFailureCooldown
            }
        }
        let cooldown = max(baseCooldown, TimeInterval(retryAfter))
        return now.timeIntervalSince(lastAttempt) < cooldown
    }

    /// Reads each pending account's saved credential serially into an
    /// immutable batch context. Per-account read failures become unavailable
    /// results without touching the network, and no secure store is ever
    /// entered concurrently from the network phase. A cancelled batch stops
    /// credential reads immediately instead of doing superseded work.
    private func prepareBatchContext(accountIds: [String], generation: Int, providerId: String?) async -> UsageBatchContext {
        guard !Task.isCancelled else {
            return UsageBatchContext(providerId: providerId, generation: generation, accounts: [])
        }
        var accounts: [UsageBatchAccount] = []
        for accountId in accountIds {
            guard !Task.isCancelled else { break }
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
    /// the next child only when one completes. Queued children are not started
    /// once the batch is cancelled, so a superseded generation stops scheduling
    /// new work (its in-flight children still finish and are dropped by the
    /// generation guard).
    private func fetchUsageBatch(context: UsageBatchContext) async {
        await withTaskGroup(of: UsageFetchOutcome.self) { group in
            var queueIndex = 0

            func startNext() {
                guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                self.publishUsage(accountId: outcome.accountId, generation: context.generation, outcome: outcome)
                startNext()
            }
        }
    }

    /// Fetches one account's usage. Failures are isolated per account and
    /// surface as that account's unavailable state only. The attempt timestamp
    /// is recorded before the credential guard so missing-credential rows also
    /// respect the failure cooldown.
    private func fetchUsageForItem(_ item: UsageBatchAccount) async -> UsageFetchOutcome {
        guard !Task.isCancelled else {
            return UsageFetchOutcome(accountId: item.accountId, state: .unavailable(reason: nil), retryAfterSeconds: nil)
        }
        recordUsageAttempt(accountId: item.accountId)
        guard let authData = item.authData else {
            return UsageFetchOutcome(
                accountId: item.accountId,
                state: .unavailable(reason: SwitcherooUsageError.noCredential.diagnosticMessage),
                retryAfterSeconds: nil
            )
        }

        guard !Task.isCancelled else {
            return UsageFetchOutcome(accountId: item.accountId, state: .unavailable(reason: nil), retryAfterSeconds: nil)
        }
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
        usageLastAttemptByAccount[accountId] = clock()
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
        if case .loaded = outcome.state {
            usageFailureCountByAccount[accountId] = nil
        } else {
            usageFailureCountByAccount[accountId] = (usageFailureCountByAccount[accountId] ?? 0) + 1
        }
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
        // A provider change invalidates every cached usage row: force a
        // generation boundary so stale results from the previous provider can
        // never land and the new provider's rows are (re)populated.
        refresh(usageTrigger: .accountSetChanged)
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
