import Foundation

public final class SwitcherooEngine: @unchecked Sendable {
    private let lock = NSLock()

    private let configStore: SwitcherooConfigStoring
    private let secureStore: SwitcherooSecureStoring
    private let fileIO: SwitcherooFileIO
    private let paths: SwitcherooPaths
    private let providers: [String: any AgentProvider]

    private var config: SwitcherooConfig

    public init(
        configStore: SwitcherooConfigStoring,
        secureStore: SwitcherooSecureStoring,
        fileIO: SwitcherooFileIO,
        paths: SwitcherooPaths,
        providers: [any AgentProvider]
    ) throws {
        self.configStore = configStore
        self.secureStore = secureStore
        self.fileIO = fileIO
        self.paths = paths

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

    public func finalizeAddAccount(_ pending: PendingLogin, setActive: Bool) throws {
        let provider = try requireProvider(pending.providerId)

        let authData = try fileIO.readFile(path: pending.expectedAuthFilePath)
        guard !authData.isEmpty else {
            throw SwitcherooError.invalidAuthFile(path: pending.expectedAuthFilePath)
        }

        try secureStore.store(authData, key: secureStoreKey(providerId: provider.id, accountId: pending.accountId))

        var next = withConfig { $0 }
        if next.defaultProviderId == nil {
            next.defaultProviderId = provider.id
        }

        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

        var account = SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        account.lastUsedAt = setActive ? Date() : nil
        providerState.accounts.append(account)
        if setActive {
            providerState.activeAccountId = pending.accountId
            try fileIO.writeFileAtomically(
                authData,
                path: activeAuthFilePath(providerState: providerState, provider: provider),
                permissions: 0o600
            )
        }

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)

        try? paths.removeItem(path: pending.providerHomePath)
    }

    // UI-focused helper: create an account without asking for a name up-front.
    // Name is derived from the auth.json snapshot after login/import.
    public func startAddAccount(providerId: String? = nil) throws -> PendingLogin {
        try startAddAccount(providerId: providerId, name: "New account")
    }

    public func finalizeAddAccountWithDerivedName(_ pending: PendingLogin, setActiveIfFirst: Bool) throws -> SwitcherooAccount {
        let provider = try requireProvider(pending.providerId)

        let authData = try fileIO.readFile(path: pending.expectedAuthFilePath)
        guard !authData.isEmpty else {
            throw SwitcherooError.invalidAuthFile(path: pending.expectedAuthFilePath)
        }

        try secureStore.store(authData, key: secureStoreKey(providerId: provider.id, accountId: pending.accountId))

        var next = withConfig { $0 }
        if next.defaultProviderId == nil {
            next.defaultProviderId = provider.id
        }

        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
        let shouldSetActive = setActiveIfFirst && providerState.accounts.isEmpty

        let derivedName = defaultAccountName(fromAuthData: authData)
        var account = SwitcherooAccount(id: pending.accountId, name: derivedName)
        account.lastUsedAt = shouldSetActive ? Date() : nil
        providerState.accounts.append(account)

        if shouldSetActive {
            providerState.activeAccountId = pending.accountId
            try fileIO.writeFileAtomically(
                authData,
                path: activeAuthFilePath(providerState: providerState, provider: provider),
                permissions: 0o600
            )
        }

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)

        try? paths.removeItem(path: pending.providerHomePath)
        return account
    }

    public func importCurrentAccount(providerId: String? = nil, name: String, setActive: Bool) throws -> SwitcherooAccount {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        var next = withConfig { $0 }
        if next.defaultProviderId == nil {
            next.defaultProviderId = provider.id
        }

        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
        let data = try readActiveAuthData(providerState: providerState, provider: provider)

        var account = SwitcherooAccount(name: name)
        try secureStore.store(data, key: secureStoreKey(providerId: provider.id, accountId: account.id))
        if setActive {
            account.lastUsedAt = Date()
            providerState.activeAccountId = account.id
        }
        providerState.accounts.append(account)

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)

        return account
    }

    public func importCurrentAccountWithDerivedName(providerId: String? = nil, setActiveIfFirst: Bool) throws -> SwitcherooAccount {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        var next = withConfig { $0 }
        if next.defaultProviderId == nil {
            next.defaultProviderId = provider.id
        }

        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)
        let data = try readActiveAuthData(providerState: providerState, provider: provider)

        let derivedName = defaultAccountName(fromAuthData: data)
        let shouldSetActive = setActiveIfFirst && providerState.accounts.isEmpty

        var account = SwitcherooAccount(name: derivedName)
        try secureStore.store(data, key: secureStoreKey(providerId: provider.id, accountId: account.id))
        if shouldSetActive {
            account.lastUsedAt = Date()
            providerState.activeAccountId = account.id
        }
        providerState.accounts.append(account)

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)

        return account
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

    public func switchToAccount(providerId: String? = nil, accountIdOrName: String) throws {
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        var next = withConfig { $0 }
        var providerState = next.providers.first(where: { $0.id == provider.id }) ?? SwitcherooProvider(id: provider.id)

        guard let target = resolveAccount(in: providerState, idOrName: accountIdOrName) else {
            throw SwitcherooError.accountNotFound
        }

        let data = try secureStore.load(key: secureStoreKey(providerId: provider.id, accountId: target.id))
        try fileIO.writeFileAtomically(
            data,
            path: activeAuthFilePath(providerState: providerState, provider: provider),
            permissions: 0o600
        )

        providerState.activeAccountId = target.id
        providerState.accounts = providerState.accounts.map { acc in
            var copy = acc
            if copy.id == target.id {
                copy.lastUsedAt = Date()
            }
            return copy
        }

        next.providers.removeAll(where: { $0.id == provider.id })
        next.providers.append(providerState)
        try persist(next)
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
        let pid = try resolveProviderId(providerId)
        let provider = try requireProvider(pid)

        let providerState = providerConfig(providerId: provider.id)
        guard let active = try activeAccount(providerId: provider.id) else { return false }
        let data = try readActiveAuthData(providerState: providerState, provider: provider)
        try secureStore.store(data, key: secureStoreKey(providerId: provider.id, accountId: active.id))
        return true
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

    private func withConfig<T>(_ body: (SwitcherooConfig) -> T) -> T {
        lock.lock()
        let snap = config
        lock.unlock()
        return body(snap)
    }
}
