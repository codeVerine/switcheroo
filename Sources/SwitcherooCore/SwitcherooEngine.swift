import Foundation

public final class SwitcherooEngine: @unchecked Sendable {
    private let lock = NSLock()

    private let configStore: SwitcherooConfigStoring
    private let secureStore: SwitcherooSecureStoring
    private let fileIO: SwitcherooFileIO
    private let paths: SwitcherooPaths
    private let providers: [String: any AgentProvider]
    private let authTargetAdapters: [any AuthTargetAdapter]

    private var config: SwitcherooConfig

    public init(
        configStore: SwitcherooConfigStoring,
        secureStore: SwitcherooSecureStoring,
        fileIO: SwitcherooFileIO,
        paths: SwitcherooPaths,
        providers: [any AgentProvider],
        authTargetAdapters: [any AuthTargetAdapter]
    ) throws {
        // The primary Codex target must never silently disappear: an engine
        // without adapters would persist account switches without swapping any
        // auth file, so an empty target set is rejected here.
        guard !authTargetAdapters.isEmpty else {
            throw SwitcherooError.noAuthTargetsConfigured
        }

        self.configStore = configStore
        self.secureStore = secureStore
        self.fileIO = fileIO
        self.paths = paths
        self.authTargetAdapters = authTargetAdapters

        var map: [String: any AgentProvider] = [:]
        for provider in providers {
            map[provider.id] = provider
        }
        self.providers = map

        self.config = try configStore.load()
        try reconcilePendingTransactions()
    }

    public func listAccounts(providerId: String? = nil) throws -> [SwitcherooAccount] {
        let pid = try resolveProviderId(providerId)
        let provider = providerConfig(providerId: pid)
        return provider.accounts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func activeAccount(providerId: String? = nil) throws -> SwitcherooAccount? {
        let pid = try resolveProviderId(providerId)
        let provider = providerConfig(providerId: pid)
        guard let id = provider.activeAccountId else { return nil }
        return provider.accounts.first(where: { $0.id == id })
    }

    public func startAddAccount(providerId: String? = nil, name: String) throws -> PendingLogin {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        let account = SwitcherooAccount(name: name)
        let pending = try provider.prepareLogin(accountId: account.id, accountName: account.name, paths: paths)
        try provider.launchLoginInteractive(pending: pending)
        return pending
    }

    @discardableResult
    public func finalizeAddAccount(_ pending: PendingLogin, setActive: Bool) throws -> SwitcherooAccountWriteResult {
        let provider = try requireProvider(pending.providerId)

        let authData = try fileIO.readFile(path: pending.expectedAuthFilePath)
        guard !authData.isEmpty else {
            throw SwitcherooError.invalidAuthFile(path: pending.expectedAuthFilePath)
        }

        let result = try upsertAuthSnapshot(
            provider: provider,
            authData: authData,
            newAccountId: pending.accountId,
            newAccountName: pending.accountName,
            allowCreate: true,
            activate: setActive,
            activateIfFirst: false,
            writeActiveAuthFileWhenActivated: true
        )

        try? paths.removeItem(path: pending.providerHomePath)
        return result
    }

    // UI-focused helper: create an account without asking for a name up-front.
    // Name is derived from the auth.json snapshot after login/import.
    public func startAddAccount(providerId: String? = nil) throws -> PendingLogin {
        try startAddAccount(providerId: providerId, name: "New account")
    }

    public func finalizeAddAccountWithDerivedName(_ pending: PendingLogin, setActiveIfFirst: Bool) throws -> SwitcherooAccountWriteResult {
        let provider = try requireProvider(pending.providerId)

        let authData = try fileIO.readFile(path: pending.expectedAuthFilePath)
        guard !authData.isEmpty else {
            throw SwitcherooError.invalidAuthFile(path: pending.expectedAuthFilePath)
        }

        let derivedName = defaultAccountName(fromAuthData: authData)
        let result = try upsertAuthSnapshot(
            provider: provider,
            authData: authData,
            newAccountId: pending.accountId,
            newAccountName: derivedName,
            allowCreate: true,
            activate: false,
            activateIfFirst: setActiveIfFirst,
            writeActiveAuthFileWhenActivated: true
        )

        try? paths.removeItem(path: pending.providerHomePath)
        return result
    }

    @discardableResult
    public func importCurrentAccount(providerId: String? = nil, name: String, setActive: Bool) throws -> SwitcherooAccountWriteResult {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        let providerState = providerConfig(providerId: provider.id)
        let data = try readActiveAuthData(providerState: providerState, provider: provider)

        return try upsertAuthSnapshot(
            provider: provider,
            authData: data,
            newAccountId: UUID().uuidString,
            newAccountName: name,
            allowCreate: true,
            activate: setActive,
            activateIfFirst: false,
            writeActiveAuthFileWhenActivated: true
        )
    }

    public func importCurrentAccountWithDerivedName(providerId: String? = nil, setActiveIfFirst: Bool) throws -> SwitcherooAccountWriteResult {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        let providerState = providerConfig(providerId: provider.id)
        let data = try readActiveAuthData(providerState: providerState, provider: provider)

        let derivedName = defaultAccountName(fromAuthData: data)
        return try upsertAuthSnapshot(
            provider: provider,
            authData: data,
            newAccountId: UUID().uuidString,
            newAccountName: derivedName,
            allowCreate: true,
            activate: false,
            activateIfFirst: setActiveIfFirst,
            writeActiveAuthFileWhenActivated: true
        )
    }

    public func renameAccount(providerId: String? = nil, accountId: String, newName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        try performTransaction {
            let previousConfig = try loadConfigForTransaction()
            var providerState = previousConfig.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
            guard providerState.accounts.contains(where: { $0.id == accountId }) else {
                throw SwitcherooError.accountNotFound
            }

            providerState.accounts = providerState.accounts.map { acc in
                var copy = acc
                if copy.id == accountId {
                    copy.name = newName
                }
                return copy
            }

            var next = previousConfig
            replaceProviderState(providerState, in: &next)
            return TransactionPlan(
                previousConfig: previousConfig,
                nextConfig: next,
                keychainChanges: [],
                prepareTargets: { [] },
                mutateConfig: { _ in }
            )
        }
    }

    public func accessTokenExpiryByAccountId(providerId: String? = nil) throws -> [String: Date] {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)
        let providerState = providerConfig(providerId: provider.id)

        var result: [String: Date] = [:]
        for acc in providerState.accounts {
            guard let data = try? secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: acc.id)) else {
                continue
            }
            guard let summary = CodexAuthParsing.summarize(authJSONData: data) else { continue }
            guard let exp = summary.accessTokenExpiry else { continue }
            result[acc.id] = exp
        }
        return result
    }

    public func metadataByAccountId(providerId: String? = nil) throws -> [String: SwitcherooAccountMetadata] {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)
        let providerState = providerConfig(providerId: provider.id)

        var result: [String: SwitcherooAccountMetadata] = [:]
        for acc in providerState.accounts {
            guard let data = try? secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: acc.id)) else {
                continue
            }
            guard let summary = CodexAuthParsing.summarize(authJSONData: data) else { continue }
            result[acc.id] = SwitcherooAccountMetadata(
                email: summary.email,
                accessTokenExpiry: summary.accessTokenExpiry
            )
        }
        return result
    }

    /// Loads the raw saved auth snapshot (opaque bytes) for an account.
    ///
    /// The caller is responsible for keeping the returned bytes in memory and
    /// never persisting or logging them.
    public func accountAuthData(providerId: String? = nil, accountId: String) throws -> Data {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)
        let providerState = providerConfig(providerId: provider.id)

        guard providerState.accounts.contains(where: { $0.id == accountId }) else {
            throw SwitcherooError.accountNotFound
        }
        return try secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: accountId))
    }

    public func switchToAccount(providerId: String? = nil, accountIdOrName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        try performTransaction {
            let previousConfig = try loadConfigForTransaction()
            let providerState = previousConfig.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

            guard let target = resolveAccount(in: providerState, idOrName: accountIdOrName) else {
                throw SwitcherooError.accountNotFound
            }

            let data = try secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: target.id))
            return TransactionPlan(
                previousConfig: previousConfig,
                nextConfig: previousConfig,
                keychainChanges: [],
                prepareTargets: {
                    try self.prepareTargetDocuments(fromAuthData: data, providerState: providerState)
                },
                mutateConfig: { config in
                    config.providers.removeAll(where: { $0.id == provider.id })
                    var updated = providerState
                    updated.activeAccountId = target.id
                    updated.accounts = updated.accounts.map { acc in
                        var copy = acc
                        if copy.id == target.id {
                            copy.lastUsedAt = Date()
                        }
                        return copy
                    }
                    config.providers.append(updated)
                }
            )
        }
    }

    public func deleteAccount(providerId: String? = nil, accountIdOrName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        try performTransaction {
            let previousConfig = try loadConfigForTransaction()
            var providerState = previousConfig.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

            guard let target = resolveAccount(in: providerState, idOrName: accountIdOrName) else {
                throw SwitcherooError.accountNotFound
            }

            let key = secureStoreKey(providerId: provider.id, accountId: target.id)
            let previousStoredData: Data?
            if try secureStore.itemExists(key: key) {
                previousStoredData = try secureStore.load(key: key)
            } else {
                previousStoredData = nil
            }

            providerState.accounts.removeAll(where: { $0.id == target.id })
            if providerState.activeAccountId == target.id {
                providerState.activeAccountId = nil
            }

            var next = previousConfig
            replaceProviderState(providerState, in: &next)
            return TransactionPlan(
                previousConfig: previousConfig,
                nextConfig: next,
                keychainChanges: [KeychainChange(op: .delete, key: key, previous: previousStoredData)],
                prepareTargets: { [] },
                mutateConfig: { _ in }
            )
        }
    }

    public func syncActiveAccountSnapshotIfNeeded(providerId: String? = nil) throws -> Bool {
        let result = try syncActiveAccountSnapshot(providerId: providerId)
        return result.disposition == .updatedExisting
    }

    public func syncActiveAccountSnapshot(providerId: String? = nil) throws -> SwitcherooActiveSnapshotSyncResult {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        let providerState = providerConfig(providerId: provider.id)
        guard !providerState.accounts.isEmpty else {
            return SwitcherooActiveSnapshotSyncResult(
                disposition: .skippedUnmatchedIdentity,
                account: nil,
                accessTokenExpiry: nil
            )
        }
        let active = providerState.activeAccountId.flatMap { id in
            providerState.accounts.first(where: { $0.id == id })
        }
        var accessTokenExpiry: Date?
        var sourceHasIdentity = false
        let result = try upsertAuthSnapshot(
            provider: provider,
            authData: nil,
            loadAuthData: { currentProviderState in
                let data = try self.readActiveAuthData(providerState: currentProviderState, provider: provider)
                accessTokenExpiry = CodexAuthParsing.summarize(authJSONData: data)?.accessTokenExpiry
                sourceHasIdentity = self.authIdentityKey(from: data) != nil
                return data
            },
            newAccountId: active?.id ?? UUID().uuidString,
            newAccountName: active?.name ?? "Active account",
            allowCreate: false,
            activate: true,
            activateIfFirst: false,
            writeActiveAuthFileWhenActivated: false
        )
        let disposition: SwitcherooActiveSnapshotSyncDisposition
        if !sourceHasIdentity {
            disposition = .skippedNoIdentity
        } else {
            switch result.disposition {
            case .updatedExisting, .created:
                disposition = .updatedExisting
            case .skippedUnmatchedIdentity:
                disposition = .skippedUnmatchedIdentity
            }
        }

        return SwitcherooActiveSnapshotSyncResult(
            disposition: disposition,
            account: disposition == .updatedExisting ? result.account : nil,
            accessTokenExpiry: accessTokenExpiry
        )
    }

    public func activeAccessTokenExpiry(providerId: String? = nil) throws -> Date? {
        try activeAuthInfo(providerId: providerId).accessTokenExpiry
    }

    public func activeAuthIdentityKey(providerId: String? = nil) throws -> String? {
        try activeAuthInfo(providerId: providerId).identityKey
    }

    public func activeAuthInfo(providerId: String? = nil) throws -> SwitcherooActiveAuthInfo {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)
        let providerState = providerConfig(providerId: provider.id)
        let data = try readActiveAuthData(providerState: providerState, provider: provider)

        let summary = CodexAuthParsing.summarize(authJSONData: data)
        return SwitcherooActiveAuthInfo(
            identityKey: summary.flatMap { authIdentityKey(from: $0) },
            accessTokenExpiry: summary?.accessTokenExpiry
        )
    }

    private func upsertAuthSnapshot(
        provider: any AgentProvider,
        authData: Data?,
        loadAuthData: ((SwitcherooProvider) throws -> Data)? = nil,
        newAccountId: String,
        newAccountName: String,
        allowCreate: Bool,
        activate: Bool,
        activateIfFirst: Bool,
        writeActiveAuthFileWhenActivated: Bool
    ) throws -> SwitcherooAccountWriteResult {
        var result = SwitcherooAccountWriteResult(disposition: .skippedUnmatchedIdentity, account: nil)

        try performTransaction {
            let previousConfig = try loadConfigForTransaction()
            var next = previousConfig
            if next.defaultProviderId == nil {
                next.defaultProviderId = provider.id
            }

            var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
            let loadedAuthData: Data?
            if let authData {
                loadedAuthData = authData
            } else {
                loadedAuthData = try loadAuthData?(providerState)
            }
            guard let sourceAuthData = loadedAuthData else {
                throw SwitcherooError.invalidAuthFile(path: provider.defaultActiveAuthFilePath)
            }
            let identityKey = authIdentityKey(from: sourceAuthData)
            let willWriteActiveFile = writeActiveAuthFileWhenActivated
                && (activate || activateIfFirst && !hasActiveAccount(providerState))

            if let existing = matchingAccount(identityKey: identityKey, providerId: provider.id, providerState: &providerState) {
                let key = secureStoreKey(providerId: provider.id, accountId: existing.id)
                let previousStoredData: Data?
                if try secureStore.itemExists(key: key) {
                    previousStoredData = try secureStore.load(key: key)
                } else {
                    previousStoredData = nil
                }

                let shouldActivate = activate || activateIfFirst && !hasActiveAccount(providerState)
                var affected: SwitcherooAccount?
                providerState.accounts = providerState.accounts.map { account in
                    var copy = account
                    if copy.id == existing.id {
                        copy.identityKey = copy.identityKey ?? identityKey
                        if shouldActivate {
                            copy.lastUsedAt = Date()
                        }
                        affected = copy
                    }
                    return copy
                }

                if shouldActivate {
                    providerState.activeAccountId = existing.id
                }
                replaceProviderState(providerState, in: &next)
                result = SwitcherooAccountWriteResult(disposition: .updatedExisting, account: affected ?? existing)
                return TransactionPlan(
                    previousConfig: previousConfig,
                    nextConfig: next,
                    keychainChanges: [KeychainChange(op: .store(sourceAuthData), key: key, previous: previousStoredData)],
                    journaled: willWriteActiveFile,
                    prepareTargets: willWriteActiveFile ? {
                        try self.prepareTargetDocuments(fromAuthData: sourceAuthData, providerState: providerState)
                    } : { [] },
                    mutateConfig: { _ in }
                )
            }

            guard allowCreate else {
                result = SwitcherooAccountWriteResult(disposition: .skippedUnmatchedIdentity, account: nil)
                return TransactionPlan(
                    previousConfig: previousConfig,
                    nextConfig: previousConfig,
                    keychainChanges: [],
                    journaled: false,
                    prepareTargets: { [] },
                    mutateConfig: { _ in }
                )
            }

            let shouldActivate = activate || activateIfFirst && !hasActiveAccount(providerState)
            var account = SwitcherooAccount(id: newAccountId, name: newAccountName, identityKey: identityKey)
            account.lastUsedAt = shouldActivate ? Date() : nil

            let key = secureStoreKey(providerId: provider.id, accountId: account.id)
            providerState.accounts.append(account)
            if shouldActivate {
                providerState.activeAccountId = account.id
            }
            replaceProviderState(providerState, in: &next)
            result = SwitcherooAccountWriteResult(disposition: .created, account: account)
            return TransactionPlan(
                previousConfig: previousConfig,
                nextConfig: next,
                keychainChanges: [KeychainChange(op: .store(sourceAuthData), key: key, previous: nil)],
                journaled: willWriteActiveFile,
                prepareTargets: willWriteActiveFile ? {
                    try self.prepareTargetDocuments(fromAuthData: sourceAuthData, providerState: providerState)
                } : { [] },
                mutateConfig: { _ in }
            )
        }

        return result
    }

    private func matchingAccount(
        identityKey: String?,
        providerId: String,
        providerState: inout SwitcherooProvider
    ) -> SwitcherooAccount? {
        guard let identityKey else { return nil }

        for index in providerState.accounts.indices {
            if providerState.accounts[index].identityKey == identityKey {
                return providerState.accounts[index]
            }
            guard let storedData = try? secureStore.load(key: secureStoreKey(providerId: providerId, accountId: providerState.accounts[index].id)) else {
                continue
            }
            guard let storedIdentityKey = authIdentityKey(from: storedData) else { continue }

            // Identity key semantics can evolve (ex: moving from account_id-only to account_id+email/user_id).
            // Always recompute and backfill from the stored snapshot so older configs can still match and
            // we avoid false-positive overwrites.
            if providerState.accounts[index].identityKey != storedIdentityKey {
                providerState.accounts[index].identityKey = storedIdentityKey
            }
            if storedIdentityKey == identityKey {
                return providerState.accounts[index]
            }
        }

        return nil
    }

    private func readActiveAuthData(providerState: SwitcherooProvider, provider: any AgentProvider) throws -> Data {
        let path = activeAuthFilePath(providerState: providerState, provider: provider)
        guard fileIO.fileExists(path: path) else {
            throw SwitcherooError.missingAuthFile(path: path)
        }
        let data = try fileIO.readFile(path: path)
        guard !data.isEmpty else {
            throw SwitcherooError.invalidAuthFile(path: path)
        }
        return data
    }

    private func activeAuthFilePath(providerState: SwitcherooProvider, provider: any AgentProvider) -> String {
        providerState.activeAuthFilePathOverride ?? provider.defaultActiveAuthFilePath
    }

    private func resolveProviderId(_ providerId: String?) throws -> String {
        if let providerId, !providerId.isEmpty {
            return providerId
        }
        if let id = withConfig({ $0.defaultProviderId }) {
            return id
        }
        if providers.count == 1, let id = providers.keys.first {
            return id
        }
        throw SwitcherooError.providerNotFound(providerId: providerId ?? "(none)")
    }

    private func requireProvider(_ id: String) throws -> any AgentProvider {
        guard let provider = providers[id] else {
            throw SwitcherooError.providerNotFound(providerId: id)
        }
        return provider
    }

    private func providerConfig(providerId: String) -> SwitcherooProvider {
        withConfig { config in
            config.providers.first(where: { $0.id == providerId }) ?? SwitcherooProvider(id: providerId)
        }
    }

    private func resolveAccount(in provider: SwitcherooProvider, idOrName: String) -> SwitcherooAccount? {
        if let exact = provider.accounts.first(where: { $0.id == idOrName }) {
            return exact
        }
        if let byName = provider.accounts.first(where: { $0.name == idOrName }) {
            return byName
        }
        if let byPrefix = provider.accounts.first(where: { $0.id.lowercased().hasPrefix(idOrName.lowercased()) }) {
            return byPrefix
        }
        return nil
    }

    private func secureStoreKey(providerId: String, accountId: String) -> String {
        "\(providerId):\(accountId)"
    }

    private func authIdentityKey(from authData: Data) -> String? {
        guard let summary = CodexAuthParsing.summarize(authJSONData: authData) else { return nil }
        return authIdentityKey(from: summary)
    }

    private func authIdentityKey(from summary: CodexAuthParsing.Summary) -> String? {
        let accountId = normalizedIdentityValue(summary.accountId)
        let userId = normalizedIdentityValue(summary.userId)
        let email = normalizedIdentityValue(summary.email)?.lowercased()

        if let accountId {
            if let userId { return "account_id:\(accountId)|user_id:\(userId)" }
            if let email { return "account_id:\(accountId)|email:\(email)" }
            return "account_id:\(accountId)"
        }
        if let userId { return "user_id:\(userId)" }
        if let email { return "email:\(email)" }
        return nil
    }

    private func normalizedIdentityValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func defaultAccountName(fromAuthData authData: Data) -> String {
        if let summary = CodexAuthParsing.summarize(authJSONData: authData) {
            if let email = summary.email, !email.isEmpty { return email }
            if let accountId = summary.accountId, !accountId.isEmpty { return accountId }
        }
        return "Imported \(formattedNow())"
    }

    private func formattedNow() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }

    private func persist(_ updated: SwitcherooConfig) throws {
        lock.lock()
        config = updated
        lock.unlock()
        try configStore.save(updated)
    }

    private func replaceProviderState(_ providerState: SwitcherooProvider, in config: inout SwitcherooConfig) {
        config.providers.removeAll(where: { $0.id == providerState.id })
        config.providers.append(providerState)
    }

    private func hasActiveAccount(_ providerState: SwitcherooProvider) -> Bool {
        guard let activeAccountId = providerState.activeAccountId else { return false }
        return providerState.accounts.contains(where: { $0.id == activeAccountId })
    }

    private func withConfig<T>(_ body: (SwitcherooConfig) -> T) -> T {
        lock.lock()
        let snap = config
        lock.unlock()
        return body(snap)
    }

    private func loadConfigForTransaction() throws -> SwitcherooConfig {
        let current = try configStore.load()
        lock.lock()
        config = current
        lock.unlock()
        return current
    }

    private func configsMatch(_ lhs: SwitcherooConfig, _ rhs: SwitcherooConfig) -> Bool {
        lhs == rhs
    }

    // MARK: - Auth target synchronization

    private struct PreparedTarget {
        let adapter: any AuthTargetAdapter
        let destinationPath: String
        let previous: Data?
        let credential: AuthTargetCredential?
        let sourceAuthData: Data
    }

    private struct WrittenTarget {
        let adapter: any AuthTargetAdapter
        let destinationPath: String
        let previous: Data?
        let writtenData: Data
    }

    /// Signals that a target write failed and this call's own compare-and-swap
    /// restore of previously-written targets could not fully recover; the
    /// caller must still attempt Keychain and config rollback and aggregate
    /// every failure.
    private struct TargetRollbackIncomplete: Error {
        let unrestoredPaths: [String]
    }

    private struct KeychainChange {
        enum Operation {
            case store(Data)
            case delete
        }

        let op: Operation
        let key: String
        let previous: Data?
    }

    private struct TransactionPlan {
        let previousConfig: SwitcherooConfig
        let nextConfig: SwitcherooConfig
        let keychainChanges: [KeychainChange]
        let journaled: Bool
        let prepareTargets: () throws -> [PreparedTarget]
        let mutateConfig: (inout SwitcherooConfig) throws -> Void

        init(
            previousConfig: SwitcherooConfig,
            nextConfig: SwitcherooConfig,
            keychainChanges: [KeychainChange],
            journaled: Bool = true,
            prepareTargets: @escaping () throws -> [PreparedTarget],
            mutateConfig: @escaping (inout SwitcherooConfig) throws -> Void
        ) {
            self.previousConfig = previousConfig
            self.nextConfig = nextConfig
            self.keychainChanges = keychainChanges
            self.journaled = journaled
            self.prepareTargets = prepareTargets
            self.mutateConfig = mutateConfig
        }
    }

    private func performTransaction(
        nextConfig: SwitcherooConfig,
        previousConfig: SwitcherooConfig,
        keychainChanges: [KeychainChange],
        prepareTargets: @escaping () throws -> [PreparedTarget],
        mutateConfig: @escaping (inout SwitcherooConfig) throws -> Void
    ) throws {
        try performTransaction {
            let persistedConfig = try configStore.load()
            guard configsMatch(persistedConfig, previousConfig) else {
                throw SwitcherooError.configUnavailable
            }
            return TransactionPlan(
                previousConfig: previousConfig,
                nextConfig: nextConfig,
                keychainChanges: keychainChanges,
                prepareTargets: prepareTargets,
                mutateConfig: mutateConfig
            )
        }
    }

    /// Resolve and validate every target, capture pre-images, and reject
    /// colliding destinations - all read-only, so failures abort the
    /// transaction before any publication.
    private func prepareTargetDocuments(fromAuthData authData: Data, providerState: SwitcherooProvider) throws -> [PreparedTarget] {
        let resolved = authTargetAdapters.map { adapter in
            (adapter: adapter, path: fileIO.canonicalDestinationPath(adapter.destinationAuthFilePath(forProviderState: providerState)))
        }

        var seen: [String: String] = [:]
        for entry in resolved {
            if let first = seen[entry.path] {
                throw AuthTargetSyncError.destinationCollision(path: entry.path, targets: "\(first), \(entry.adapter.id)")
            }
            seen[entry.path] = entry.adapter.id
        }

        var prepared: [PreparedTarget] = []
        for entry in resolved {
            let credential = try entry.adapter.convertedCredential(fromSourceAuthData: authData)

            let existing: Data?
            if fileIO.fileExists(path: entry.path) {
                do {
                    existing = try fileIO.readFile(path: entry.path)
                } catch {
                    throw AuthTargetSyncError.destinationReadFailed(
                        targetId: entry.adapter.id,
                        path: entry.path,
                        reason: error.localizedDescription
                    )
                }
            } else {
                existing = nil
            }
            try entry.adapter.validateExistingDestination(existingDestinationData: existing, destinationPath: entry.path)

            prepared.append(PreparedTarget(
                adapter: entry.adapter,
                destinationPath: entry.path,
                previous: existing,
                credential: credential,
                sourceAuthData: authData
            ))
        }
        return prepared
    }

    /// Publish every prepared target through its adapter. On a write failure,
    /// previously written targets are restored (compare-and-swap guarded);
    /// targets that cannot be restored are reported by the caller.
    private func writeTargetDocuments(
        _ prepared: [PreparedTarget],
        willWrite: (Int) throws -> Void,
        didWrite: (Int, AuthTargetWriteResult) throws -> Void
    ) throws -> [WrittenTarget] {
        func rollbackAndThrow(item: PreparedTarget, written: [WrittenTarget], reason: String) throws -> Never {
            let unrecoverable = restoreTargetFiles(written)
            if !unrecoverable.isEmpty {
                throw TargetRollbackIncomplete(unrestoredPaths: unrecoverable)
            }
            throw AuthTargetSyncError.destinationWriteFailed(
                targetId: item.adapter.id,
                path: item.destinationPath,
                reason: reason
            )
        }

        var written: [WrittenTarget] = []
        for (index, item) in prepared.enumerated() {
            do {
                try willWrite(index)
            } catch {
                try rollbackAndThrow(item: item, written: written, reason: error.localizedDescription)
            }

            let result: AuthTargetWriteResult
            do {
                result = try item.adapter.writeDestination(
                    credential: item.credential,
                    sourceAuthData: item.sourceAuthData,
                    destinationPath: item.destinationPath,
                    fileIO: fileIO
                )
            } catch let error as AuthTargetPublicationError {
                let published = error.result
                written.append(WrittenTarget(
                    adapter: item.adapter,
                    destinationPath: item.destinationPath,
                    previous: published.previousData,
                    writtenData: published.writtenData
                ))
                do {
                    try didWrite(index, published)
                } catch {
                    try rollbackAndThrow(item: item, written: written, reason: error.localizedDescription)
                }
                try rollbackAndThrow(item: item, written: written, reason: error.reason)
            } catch {
                try rollbackAndThrow(item: item, written: written, reason: error.localizedDescription)
            }

            written.append(WrittenTarget(
                adapter: item.adapter,
                destinationPath: item.destinationPath,
                previous: result.previousData,
                writtenData: result.writtenData
            ))
            do {
                try didWrite(index, result)
            } catch {
                try rollbackAndThrow(item: item, written: written, reason: error.localizedDescription)
            }
        }
        return written
    }

    /// Restore previously written target files to their pre-write state. Returns
    /// the paths that could not be restored (for example, because another
    /// process modified the file after our write).
    private func restoreTargetFiles(_ written: [WrittenTarget]) -> [String] {
        var unrecoverable: [String] = []
        for entry in written.reversed() {
            if !entry.adapter.restoreDestination(
                previous: entry.previous,
                expectedCurrent: entry.writtenData,
                destinationPath: entry.destinationPath,
                fileIO: fileIO
            ) {
                unrecoverable.append(entry.destinationPath)
            }
        }
        return unrecoverable
    }

    private func applyKeychainChange(_ change: KeychainChange) throws {
        switch change.op {
        case .store(let data):
            try secureStore.store(data, key: change.key)
        case .delete:
            try secureStore.delete(key: change.key)
        }
    }

    private func rollbackKeychainChange(_ change: KeychainChange) throws {
        switch change.op {
        case .store:
            if let previous = change.previous {
                try secureStore.store(previous, key: change.key)
            } else {
                try secureStore.delete(key: change.key)
            }
        case .delete:
            if let previous = change.previous {
                try secureStore.store(previous, key: change.key)
            }
        }
    }

    /// Restore config state (in-memory and persisted). Returns false when the
    /// persisted restore fails.
    @discardableResult
    private func restoreConfig(_ config: SwitcherooConfig) -> Bool {
        lock.lock()
        self.config = config
        lock.unlock()
        do {
            try configStore.save(config)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Transaction journal and crash recovery

    private func transactionStateDirectoryPath() throws -> String {
        try paths.stateDirectoryPath()
    }

    private func transactionLockPath() throws -> String {
        (try transactionStateDirectoryPath() as NSString).appendingPathComponent("switch.lock")
    }

    private func transactionJournalPath() throws -> String {
        (try transactionStateDirectoryPath() as NSString).appendingPathComponent("transaction.json")
    }

    /// Serialized account switch: journal, mutate destinations, persist config,
    /// mark committed, clear the journal. Any failure rolls back every published
    /// mutation; a rollback that itself fails leaves the journal in place for
    /// startup reconciliation and reports every failed recovery step.
    private func performTransaction(
        buildPlan: () throws -> TransactionPlan
    ) throws {
        try fileIO.withExclusiveLock(path: transactionLockPath()) {
            try reconcilePendingTransactionsLocked()

            let plan = try buildPlan()
            if !plan.journaled {
                try performUnjournaledTransaction(plan)
                return
            }
            let preparedTargets = try plan.prepareTargets()

            var journal = TransactionJournal(
                txid: UUID().uuidString,
                createdAt: Date(),
                configCommitted: false,
                committedConfig: nil,
                previousConfig: plan.previousConfig,
                targets: preparedTargets.map {
                    TransactionJournal.Target(id: $0.adapter.id, path: $0.destinationPath, previous: $0.previous)
                },
                keychainChanges: plan.keychainChanges.map { change in
                    let opName: String
                    switch change.op {
                    case .store: opName = "store"
                    case .delete: opName = "delete"
                    }
                    return TransactionJournal.KeychainChange(op: opName, key: change.key, previous: change.previous)
                }
            )

            var next = plan.nextConfig
            var writtenTargets: [WrittenTarget] = []
            var appliedChanges: [KeychainChange] = []
            let journalPath = try transactionJournalPath()

            do {
                try writeJournal(journal)

                for change in plan.keychainChanges {
                    try applyKeychainChange(change)
                    appliedChanges.append(change)
                }

                writtenTargets = try writeTargetDocuments(preparedTargets, willWrite: { index in
                    journal.targets[index].publicationStarted = true
                    try writeJournal(journal)
                }) { index, result in
                    journal.targets[index].previous = result.previousData
                    journal.targets[index].expected = result.writtenData
                    try writeJournal(journal)
                }

                try plan.mutateConfig(&next)
                try persist(next)

                journal.committedConfig = next
                journal.configCommitted = true
                try writeJournal(journal)
            } catch let error {
                // A target-level rollback failure already left some destination
                // unrestored; still attempt Keychain and config rollback and
                // aggregate every failure. The journal must survive regardless,
                // so startup reconciliation can retry the unrestored target.
                if journal.configCommitted {
                    journal.configCommitted = false
                    do {
                        try writeJournal(journal)
                    } catch {
                        throw AuthTargetSyncError.rollbackIncomplete(
                            message: "Account switch failed before rollback could be made recoverable. A recovery record remains at \(journalPath)."
                        )
                    }
                }
                if let targetFailure = error as? TargetRollbackIncomplete {
                    let failures = targetFailure.unrestoredPaths
                        + rollbackKeychainAndConfig(appliedChanges: appliedChanges, previousConfig: plan.previousConfig)
                    throw AuthTargetSyncError.rollbackIncomplete(
                        message: "Account switch failed and could not be fully rolled back. Failed to restore: \(failures.joined(separator: "; ")). Fix or remove the affected files, then switch again. A recovery record remains at \(journalPath)."
                    )
                }
                let failures = rollbackEverything(
                    writtenTargets: writtenTargets,
                    appliedChanges: appliedChanges,
                    previousConfig: plan.previousConfig
                )
                if failures.isEmpty {
                    try? deleteJournal(txid: journal.txid)
                    throw error
                }
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Account switch failed and could not be fully rolled back. Failed to restore: \(failures.joined(separator: "; ")). Fix or remove the affected files, then switch again. A recovery record remains at \(journalPath)."
                )
            }

            try? deleteJournal(txid: journal.txid)
        }
    }

    private func performUnjournaledTransaction(_ plan: TransactionPlan) throws {
        guard !plan.keychainChanges.isEmpty || plan.nextConfig != plan.previousConfig else { return }

        var next = plan.nextConfig
        var appliedChanges: [KeychainChange] = []
        do {
            for change in plan.keychainChanges {
                try applyKeychainChange(change)
                appliedChanges.append(change)
            }
            try plan.mutateConfig(&next)
            try persist(next)
        } catch {
            let failures = rollbackKeychainAndConfig(
                appliedChanges: appliedChanges,
                previousConfig: plan.previousConfig
            )
            if failures.isEmpty {
                throw error
            }
            throw AuthTargetSyncError.rollbackIncomplete(
                message: "Account update failed and could not be fully rolled back. Failed to restore: \(failures.joined(separator: "; "))."
            )
        }
    }

    /// Undo every published mutation in reverse order, collecting every failure
    /// (targets, Keychain, config) so none is silently discarded.
    private func rollbackEverything(writtenTargets: [WrittenTarget], appliedChanges: [KeychainChange], previousConfig: SwitcherooConfig) -> [String] {
        restoreTargetFiles(writtenTargets) + rollbackKeychainAndConfig(appliedChanges: appliedChanges, previousConfig: previousConfig)
    }

    /// Undo applied Keychain changes in reverse order and restore the previous
    /// config, collecting every failure so none is silently discarded.
    private func rollbackKeychainAndConfig(appliedChanges: [KeychainChange], previousConfig: SwitcherooConfig) -> [String] {
        var failures: [String] = []

        for change in appliedChanges.reversed() {
            do {
                try rollbackKeychainChange(change)
            } catch {
                failures.append("Keychain item '\(change.key)' could not be restored")
            }
        }

        if !restoreConfig(previousConfig) {
            failures.append("config could not be restored")
        }

        return failures
    }

    private func writeJournal(_ journal: TransactionJournal) throws {
        let path = try transactionJournalPath()
        let parent = (path as NSString).deletingLastPathComponent
        try fileIO.createDirectory(path: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try fileIO.writeFileAtomically(data, path: path, permissions: 0o600)
    }

    private func deleteJournal(txid: String) throws {
        try fileIO.removeItem(path: transactionJournalPath())
    }

    /// Complete or roll back a transaction interrupted by a crash. Called at
    /// engine startup and before every new transaction (under the lock).
    private func reconcilePendingTransactions() throws {
        try fileIO.withExclusiveLock(path: transactionLockPath()) {
            try reconcilePendingTransactionsLocked()
        }
    }

    private func reconcilePendingTransactionsLocked() throws {
        let path = try transactionJournalPath()
        guard fileIO.itemExists(path: path) else { return }

        guard let data = try? fileIO.readFile(path: path),
              let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data) else {
            throw AuthTargetSyncError.rollbackIncomplete(
                message: "A transaction journal at \(path) is unreadable. Fix or remove it, then switch accounts again."
            )
        }

        if journal.configCommitted {
            guard let committedConfig = journal.committedConfig,
                  let currentConfig = try? configStore.load(),
                  currentConfig == committedConfig,
                  committedTargetsMatch(journal) else {
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Recovery of the committed account switch is ambiguous. Fix or remove the affected transaction journal at \(path), then switch accounts again."
                )
            }
            try fileIO.removeItem(path: path)
            return
        }

        if journal.targets.contains(where: { !$0.publicationMarkerPresent || ($0.publicationStarted && $0.expected == nil) }) {
            throw AuthTargetSyncError.rollbackIncomplete(
                message: "Recovery of an interrupted account switch is incomplete because published auth bytes are unavailable. Fix or remove the affected transaction journal at \(path), then switch again."
            )
        }

        var failures: [String] = []
        for target in journal.targets {
            if !restoreJournalTarget(target) {
                failures.append(target.path)
            }
        }
        for change in journal.keychainChanges.reversed() {
            do {
                try rollbackJournalKeychainChange(change)
            } catch {
                failures.append("Keychain item '\(change.key)' could not be restored")
            }
        }
        do {
            try configStore.save(journal.previousConfig)
        } catch {
            failures.append("config could not be restored")
        }

        if failures.isEmpty {
            lock.lock()
            config = journal.previousConfig
            lock.unlock()
            do {
                try fileIO.removeItem(path: path)
            } catch {
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Recovery succeeded but the transaction journal at \(path) could not be removed. Retry the operation so recovery can finish."
                )
            }
        } else {
            throw AuthTargetSyncError.rollbackIncomplete(
                message: "Recovery of an interrupted account switch failed. Failed to restore: \(failures.joined(separator: "; ")). Fix or remove the affected files, then switch again. A recovery record remains at \(path)."
            )
        }
    }

    private func committedTargetsMatch(_ journal: TransactionJournal) -> Bool {
        for target in journal.targets {
            guard target.publicationMarkerPresent,
                  target.publicationStarted,
                  let expected = target.expected,
                  fileIO.fileExists(path: target.path),
                  let current = try? fileIO.readFile(path: target.path),
                  current == expected else {
                return false
            }
        }
        return true
    }

    private func restoreJournalTarget(_ target: TransactionJournal.Target) -> Bool {
        guard target.publicationMarkerPresent, target.publicationStarted else { return true }
        guard let expected = target.expected else { return false }
        let providerStates = withConfig { $0.providers }
        let adapter = authTargetAdapters.first(where: { $0.id == target.id })
            ?? authTargetAdapters.first(where: { adapter in
                providerStates.contains { providerState in
                    fileIO.canonicalDestinationPath(adapter.destinationAuthFilePath(forProviderState: providerState)) == target.path
                }
            })
        guard let adapter else { return false }
        return adapter.restoreDestination(
            previous: target.previous,
            expectedCurrent: expected,
            destinationPath: target.path,
            fileIO: fileIO
        )
    }

    private func rollbackJournalKeychainChange(_ change: TransactionJournal.KeychainChange) throws {
        switch change.op {
        case "store":
            if let previous = change.previous {
                try secureStore.store(previous, key: change.key)
            } else {
                try secureStore.delete(key: change.key)
            }
        case "delete":
            if let previous = change.previous {
                try secureStore.store(previous, key: change.key)
            }
        default:
            break
        }
    }
}
