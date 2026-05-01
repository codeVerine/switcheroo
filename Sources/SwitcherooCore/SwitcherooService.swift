import Foundation

public final class SwitcherooService: @unchecked Sendable {
    private let lock = NSLock()

    private let configStore: ConfigStore
    private let keychain: KeychainStore
    private let authFile: CodexAuthFile
    private let paths: AppSupportPaths
    private let loginLauncher: CodexLoginLauncher

    private var config: SwitcherooConfig

    public init(
        configStore: ConfigStore = ConfigStore(),
        keychain: KeychainStore = KeychainStore(),
        authFile: CodexAuthFile = CodexAuthFile(),
        paths: AppSupportPaths = AppSupportPaths(),
        loginLauncher: CodexLoginLauncher = CodexLoginLauncher()
    ) throws {
        self.configStore = configStore
        self.keychain = keychain
        self.authFile = authFile
        self.paths = paths
        self.loginLauncher = loginLauncher
        self.config = try configStore.load()
    }

    public func listAccounts() -> [SwitcherooAccount] {
        lock.lock()
        defer { lock.unlock() }
        return config.accounts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func activeAccount() -> SwitcherooAccount? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = config.activeAccountId else { return nil }
        return config.accounts.first(where: { $0.id == id })
    }

    public func codexAuthPath() -> String {
        lock.lock()
        defer { lock.unlock() }
        return config.codexAuthPath ?? CodexAuthFile.defaultPath
    }

    public func prepareAddAccount(name: String) throws -> PendingLogin {
        let account = SwitcherooAccount(name: name)
        let loginHome = try paths.loginHomeDirectory(accountId: account.id)
        try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: true, attributes: nil)

        let expectedAuthJSON = loginHome.appendingPathComponent("auth.json", isDirectory: false).path
        return PendingLogin(
            accountId: account.id,
            accountName: account.name,
            codexHomePath: loginHome.path,
            expectedAuthJSONPath: expectedAuthJSON
        )
    }

    public func launchLoginInTerminal(_ pending: PendingLogin) throws {
        try loginLauncher.launchTerminalLogin(codexHomePath: pending.codexHomePath)
    }

    public func startAddAccount(name: String) throws -> PendingLogin {
        let pending = try prepareAddAccount(name: name)
        try launchLoginInTerminal(pending)
        return pending
    }

    public func finalizeAddAccount(_ pending: PendingLogin, setActive: Bool) throws {
        let authData = try Data(contentsOf: URL(fileURLWithPath: pending.expectedAuthJSONPath))
        guard !authData.isEmpty else {
            throw SwitcherooError.invalidCodexAuthFile(path: pending.expectedAuthJSONPath)
        }

        try keychain.storeAuthBlob(authData, accountId: pending.accountId)

        let updated = withConfig { $0 }

        var account = SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        account.lastUsedAt = setActive ? Date() : nil
        var next = updated
        next.accounts.append(account)
        if setActive {
            next.activeAccountId = pending.accountId
            try authFile.writeAuthData(authData, toPath: next.codexAuthPath ?? CodexAuthFile.defaultPath)
        }

        try persist(next)

        // Remove any leftover auth cache we created during the login flow.
        try? FileManager.default.removeItem(atPath: pending.codexHomePath)
    }

    public func importCurrentAccount(name: String, setActive: Bool) throws -> SwitcherooAccount {
        let account = SwitcherooAccount(name: name)
        let data = try authFile.readAuthData(fromPath: codexAuthPath())
        try keychain.storeAuthBlob(data, accountId: account.id)

        var updated = withConfig { $0 }

        var withLastUsed = account
        if setActive {
            withLastUsed.lastUsedAt = Date()
            updated.activeAccountId = account.id
        }
        updated.accounts.append(withLastUsed)
        try persist(updated)
        return withLastUsed
    }

    public func switchToAccount(accountId: String) throws {
        let data = try keychain.loadAuthBlob(accountId: accountId)
        try authFile.writeAuthData(data, toPath: codexAuthPath())

        var updated = withConfig { $0 }

        updated.activeAccountId = accountId
        updated.accounts = updated.accounts.map { acc in
            var copy = acc
            if copy.id == accountId {
                copy.lastUsedAt = Date()
            }
            return copy
        }
        try persist(updated)
    }

    public func deleteAccount(accountId: String) throws {
        var updated = withConfig { $0 }

        updated.accounts.removeAll { $0.id == accountId }
        if updated.activeAccountId == accountId {
            updated.activeAccountId = nil
        }
        try persist(updated)
        try keychain.deleteAuthBlob(accountId: accountId)
    }

    public func syncActiveAccountSnapshotIfNeeded() throws -> Bool {
        guard let active = activeAccount() else { return false }
        let data = try authFile.readAuthData(fromPath: codexAuthPath())
        try keychain.storeAuthBlob(data, accountId: active.id)
        return true
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
