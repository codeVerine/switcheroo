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
        authTargetAdapters: [any AuthTargetAdapter] = []
    ) throws {
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
            writeActiveAuthFileWhenActivated: setActive
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
            writeActiveAuthFileWhenActivated: false
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
            writeActiveAuthFileWhenActivated: false
        )
    }

    public func renameAccount(providerId: String? = nil, accountId: String, newName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        var next = withConfig { $0 }
        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

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

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)
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

        var next = withConfig { $0 }
        let previousConfig = next
        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

        guard let target = resolveAccount(in: providerState, idOrName: accountIdOrName) else {
            throw SwitcherooError.accountNotFound
        }

        let data = try secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: target.id))

        // Convert and merge for every auth target (Codex, Pi, ...) up front so an
        // unsupported or malformed source credential fails before any file is modified.
        let preparedTargets = try prepareTargetDocuments(fromAuthData: data, providerState: providerState)

        let written = try writeTargetDocuments(preparedTargets)

        providerState.activeAccountId = target.id
        providerState.accounts = providerState.accounts.map { acc in
            var copy = acc
            if copy.id == target.id {
                copy.lastUsedAt = Date()
            }
            return copy
        }

        do {
            replaceProviderState(providerState, in: &next)
            try persist(next)
        } catch {
            restoreConfig(previousConfig)
            let unrecoverable = restoreTargetFiles(written)
            if !unrecoverable.isEmpty {
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Account switch failed; these auth files could not be restored: \(unrecoverable.joined(separator: ", ")). Fix or remove them, then switch accounts again."
                )
            }
            throw error
        }
    }

    public func deleteAccount(providerId: String? = nil, accountIdOrName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        var next = withConfig { $0 }
        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

        guard let target = resolveAccount(in: providerState, idOrName: accountIdOrName) else {
            throw SwitcherooError.accountNotFound
        }

        providerState.accounts.removeAll(where: { $0.id == target.id })
        if providerState.activeAccountId == target.id {
            providerState.activeAccountId = nil
        }

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)

        try secureStore.delete(key: secureStoreKey(providerId: provider.id, accountId: target.id))
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
        let data = try readActiveAuthData(providerState: providerState, provider: provider)
        let summary = CodexAuthParsing.summarize(authJSONData: data)
        let accessTokenExpiry = summary?.accessTokenExpiry
        guard authIdentityKey(from: data) != nil else {
            return SwitcherooActiveSnapshotSyncResult(
                disposition: .skippedNoIdentity,
                account: nil,
                accessTokenExpiry: accessTokenExpiry
            )
        }

        let active = providerState.activeAccountId.flatMap { id in
            providerState.accounts.first(where: { $0.id == id })
        }
        let result = try upsertAuthSnapshot(
            provider: provider,
            authData: data,
            newAccountId: active?.id ?? UUID().uuidString,
            newAccountName: active?.name ?? "Active account",
            allowCreate: false,
            activate: true,
            activateIfFirst: false,
            writeActiveAuthFileWhenActivated: false
        )
        let disposition: SwitcherooActiveSnapshotSyncDisposition
        switch result.disposition {
        case .updatedExisting, .created:
            disposition = .updatedExisting
        case .skippedUnmatchedIdentity:
            disposition = .skippedUnmatchedIdentity
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
        authData: Data,
        newAccountId: String,
        newAccountName: String,
        allowCreate: Bool,
        activate: Bool,
        activateIfFirst: Bool,
        writeActiveAuthFileWhenActivated: Bool
    ) throws -> SwitcherooAccountWriteResult {
        let identityKey = authIdentityKey(from: authData)
        let previousConfig = withConfig { $0 }
        var next = previousConfig
        if next.defaultProviderId == nil {
            next.defaultProviderId = provider.id
        }

        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
        let willWriteActiveFile = writeActiveAuthFileWhenActivated
            && (activate || activateIfFirst && !hasActiveAccount(providerState))
        let preparedTargets = willWriteActiveFile
            ? try prepareTargetDocuments(fromAuthData: authData, providerState: providerState)
            : nil

        if let existing = matchingAccount(identityKey: identityKey, providerId: provider.id, providerState: &providerState) {
            let key = secureStoreKey(providerId: provider.id, accountId: existing.id)
            let previousStoredData = try? secureStore.load(key: key)
            try secureStore.store(authData, key: key)

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
                if willWriteActiveFile, let preparedTargets {
                    try commitActivatedWrite(
                        providerState: providerState,
                        config: &next,
                        previousConfig: previousConfig,
                        keychainRollback: {
                            if let previousStoredData {
                                try? self.secureStore.store(previousStoredData, key: key)
                            }
                        },
                        preparedTargets: preparedTargets
                    )
                    return SwitcherooAccountWriteResult(disposition: .updatedExisting, account: affected ?? existing)
                }
            }

            replaceProviderState(providerState, in: &next)
            try persist(next)
            return SwitcherooAccountWriteResult(disposition: .updatedExisting, account: affected ?? existing)
        }

        guard allowCreate else {
            return SwitcherooAccountWriteResult(disposition: .skippedUnmatchedIdentity, account: nil)
        }

        let shouldActivate = activate || activateIfFirst && !hasActiveAccount(providerState)
        var account = SwitcherooAccount(id: newAccountId, name: newAccountName, identityKey: identityKey)
        account.lastUsedAt = shouldActivate ? Date() : nil

        let key = secureStoreKey(providerId: provider.id, accountId: account.id)
        try secureStore.store(authData, key: key)
        providerState.accounts.append(account)

            if shouldActivate {
                providerState.activeAccountId = account.id
                if willWriteActiveFile, let preparedTargets {
                    try commitActivatedWrite(
                        providerState: providerState,
                        config: &next,
                        previousConfig: previousConfig,
                        keychainRollback: {
                            try? self.secureStore.delete(key: key)
                        },
                        preparedTargets: preparedTargets
                    )
                    return SwitcherooAccountWriteResult(disposition: .created, account: account)
                }
            }

        replaceProviderState(providerState, in: &next)
        try persist(next)
        return SwitcherooAccountWriteResult(disposition: .created, account: account)
    }

    /// Commit an activation that rewrites the active auth file: write every prepared
    /// target document (Codex whole-file replacement first, then section targets),
    /// then persist the mutated config. On any failure the operation is undone
    /// (auth files, config, and keychain) before the error propagates, so all
    /// destinations stay in sync with the pre-switch state.
    private func commitActivatedWrite(
        providerState: SwitcherooProvider,
        config: inout SwitcherooConfig,
        previousConfig: SwitcherooConfig,
        keychainRollback: () -> Void,
        preparedTargets: [PreparedTarget]
    ) throws {
        var written: [WrittenTarget] = []
        do {
            written = try writeTargetDocuments(preparedTargets)
        } catch {
            keychainRollback()
            throw error
        }

        do {
            replaceProviderState(providerState, in: &config)
            try persist(config)
        } catch {
            keychainRollback()
            restoreConfig(previousConfig)
            let unrecoverable = restoreTargetFiles(written)
            if !unrecoverable.isEmpty {
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Account switch failed; these auth files could not be restored: \(unrecoverable.joined(separator: ", ")). Fix or remove them, then switch accounts again."
                )
            }
            throw error
        }
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

    // MARK: - Auth target synchronization

    private struct PreparedTarget {
        let adapter: any AuthTargetAdapter
        let destinationPath: String
        let destinationData: Data
    }

    private struct WrittenTarget {
        let destinationPath: String
        let previous: Data?
        let writtenData: Data
    }

    /// Convert and merge the source Codex credential for every configured auth target.
    /// Performs no writes, so conversion/merge failures leave every file untouched.
    private func prepareTargetDocuments(fromAuthData authData: Data, providerState: SwitcherooProvider) throws -> [PreparedTarget] {
        var prepared: [PreparedTarget] = []
        for adapter in authTargetAdapters {
            let path = adapter.destinationAuthFilePath(forProviderState: providerState)

            let existing: Data?
            if fileIO.fileExists(path: path) {
                do {
                    existing = try fileIO.readFile(path: path)
                } catch {
                    throw AuthTargetSyncError.destinationReadFailed(
                        targetId: adapter.id,
                        path: path,
                        reason: error.localizedDescription
                    )
                }
            } else {
                existing = nil
            }

            let destinationData = try adapter.destinationDocument(fromSourceAuthData: authData, existingDestinationData: existing)
            prepared.append(PreparedTarget(adapter: adapter, destinationPath: path, destinationData: destinationData))
        }
        return prepared
    }

    /// Write prepared target documents atomically with user-only permissions.
    /// If a write fails, previously written targets are restored before the error
    /// propagates; targets that cannot be restored are named in a rollback error.
    /// Returns the written entries so callers can roll them back on later failures.
    private func writeTargetDocuments(_ prepared: [PreparedTarget]) throws -> [WrittenTarget] {
        var written: [WrittenTarget] = []
        for item in prepared {
            let previous = fileIO.fileExists(path: item.destinationPath)
                ? try? fileIO.readFile(path: item.destinationPath)
                : nil

            do {
                try fileIO.writeFileAtomically(item.destinationData, path: item.destinationPath, permissions: 0o600)
            } catch {
                let unrecoverable = restoreTargetFiles(written)
                if unrecoverable.isEmpty {
                    throw AuthTargetSyncError.destinationWriteFailed(
                        targetId: item.adapter.id,
                        path: item.destinationPath,
                        reason: error.localizedDescription
                    )
                }
                throw AuthTargetSyncError.rollbackIncomplete(
                    message: "Account switch failed; these auth files could not be restored: \(unrecoverable.joined(separator: ", ")). Fix or remove them, then switch accounts again."
                )
            }

            written.append(WrittenTarget(destinationPath: item.destinationPath, previous: previous, writtenData: item.destinationData))
        }
        return written
    }

    /// Restore previously written target files to their pre-write state. Returns the
    /// paths that could not be restored (for example, because another process
    /// modified the file after our write).
    private func restoreTargetFiles(_ written: [WrittenTarget]) -> [String] {
        var unrecoverable: [String] = []
        for entry in written.reversed() {
            if !restoreFile(path: entry.destinationPath, previous: entry.previous, expectedCurrent: entry.writtenData) {
                unrecoverable.append(entry.destinationPath)
            }
        }
        return unrecoverable
    }

    /// Restore `path` to `previous` (or remove it when it did not exist), but only if
    /// the file still contains `expectedCurrent` - that is, only if no other process
    /// modified the file after our own write. Returns false when the restore cannot
    /// be completed safely.
    private func restoreFile(path: String, previous: Data?, expectedCurrent: Data) -> Bool {
        guard fileIO.fileExists(path: path) else {
            return previous == nil
        }
        guard let current = try? fileIO.readFile(path: path), current == expectedCurrent else {
            return false
        }
        do {
            if let previous {
                try fileIO.writeFileAtomically(previous, path: path, permissions: 0o600)
            } else {
                try fileIO.removeItem(path: path)
            }
            return true
        } catch {
            return false
        }
    }

    private func restoreConfig(_ config: SwitcherooConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
        try? configStore.save(config)
    }
}
