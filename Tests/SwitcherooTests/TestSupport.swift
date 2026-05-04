import Foundation
import SwitcherooCore
import SwitcherooPresentation

final class InMemoryConfigStore: SwitcherooConfigStoring {
    var config: SwitcherooConfig
    private(set) var savedConfigs: [SwitcherooConfig] = []

    init(config: SwitcherooConfig = SwitcherooConfig()) {
        self.config = config
    }

    func load() throws -> SwitcherooConfig {
        config
    }

    func save(_ config: SwitcherooConfig) throws {
        self.config = config
        savedConfigs.append(config)
    }
}

final class InMemorySecureStore: SwitcherooSecureStoring {
    var items: [String: Data] = [:]
    private(set) var storedKeys: [String] = []
    private(set) var loadedKeys: [String] = []
    private(set) var deletedKeys: [String] = []

    func store(_ data: Data, key: String) throws {
        items[key] = data
        storedKeys.append(key)
    }

    func load(key: String) throws -> Data {
        loadedKeys.append(key)
        guard let data = items[key] else {
            throw SwitcherooError.secureStoreItemMissing
        }
        return data
    }

    func delete(key: String) throws {
        items.removeValue(forKey: key)
        deletedKeys.append(key)
    }
}

final class InMemoryFileIO: SwitcherooFileIO {
    var files: [String: Data] = [:]
    private(set) var readPaths: [String] = []
    private(set) var writes: [(path: String, data: Data, permissions: Int?)] = []

    func fileExists(path: String) -> Bool {
        files[path] != nil
    }

    func readFile(path: String) throws -> Data {
        readPaths.append(path)
        guard let data = files[path] else {
            throw SwitcherooError.missingAuthFile(path: path)
        }
        return data
    }

    func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws {
        files[path] = data
        writes.append((path: path, data: data, permissions: permissions))
    }
}

final class InMemoryPaths: SwitcherooPaths {
    let rootPath: String
    private(set) var removedPaths: [String] = []

    init(rootPath: String = "/tmp/switcheroo-tests") {
        self.rootPath = rootPath
    }

    func loginHomeDirectory(providerId: String, accountId: String) throws -> String {
        "\(rootPath)/login/\(providerId)/\(accountId)"
    }

    func removeItem(path: String) throws {
        removedPaths.append(path)
    }
}

final class StubProvider: AgentProvider {
    let id: String
    let displayName: String
    let defaultActiveAuthFilePath: String

    private(set) var prepareLoginCalls: [(accountId: String, accountName: String)] = []
    private(set) var launchLoginInteractiveCalls: [PendingLogin] = []

    init(
        id: String = "codex",
        displayName: String = "Codex",
        defaultActiveAuthFilePath: String = "~/.codex/auth.json"
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultActiveAuthFilePath = defaultActiveAuthFilePath
    }

    func prepareLogin(accountId: String, accountName: String, paths: SwitcherooPaths) throws -> PendingLogin {
        prepareLoginCalls.append((accountId: accountId, accountName: accountName))
        let homePath = try paths.loginHomeDirectory(providerId: id, accountId: accountId)
        let authPath = (homePath as NSString).appendingPathComponent("auth.json")
        return PendingLogin(
            providerId: id,
            accountId: accountId,
            accountName: accountName,
            providerHomePath: homePath,
            expectedAuthFilePath: authPath
        )
    }

    func launchLoginInteractive(pending: PendingLogin) throws {
        launchLoginInteractiveCalls.append(pending)
    }
}

final class MockSwitcherooApp: SwitcherooAppControlling {
    var state: SwitcherooAppState

    private(set) var refreshCalls = 0
    private(set) var startAddAccountNameCalls: [String] = []
    private(set) var startAddAccountCalls = 0
    private(set) var importCurrentAccountNameCalls: [String] = []
    private(set) var importCurrentAccountDerivedCalls: [Bool] = []
    private(set) var finalizeSetActiveCalls: [Bool] = []
    private(set) var finalizeDerivedCalls: [Bool] = []
    private(set) var switchCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var syncCalls = 0
    private(set) var renameCalls: [(accountId: String, newName: String)] = []

    var nextPendingLogin: PendingLogin?
    var nextImportedAccount: SwitcherooAccount?
    var nextFinalizedAccount: SwitcherooAccount?
    var nextSnapshot: SwitcherooAppState?
    var forceDerivedFinalizeToReturnNil = false

    init(state: SwitcherooAppState = SwitcherooAppState()) {
        self.state = state
    }

    func refresh() {
        refreshCalls += 1
        if let nextSnapshot {
            state = nextSnapshot
        }
    }

    func snapshot() -> SwitcherooAppState {
        state
    }

    func startAddAccount(name: String) {
        startAddAccountNameCalls.append(name)
        publishPendingLogin(accountName: name)
    }

    func startAddAccount() {
        startAddAccountCalls += 1
        publishPendingLogin(accountName: "New account")
    }

    func importCurrentAccount(name: String) {
        importCurrentAccountNameCalls.append(name)
        let account = nextImportedAccount ?? SwitcherooAccount(name: name)
        state.accounts.append(account)
        state.errorMessage = nil
        if state.activeAccountId == nil && state.accounts.count == 1 {
            state.activeAccountId = account.id
        }
    }

    func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccount? {
        importCurrentAccountDerivedCalls.append(setActiveIfFirst)
        let account = nextImportedAccount ?? SwitcherooAccount(name: "Imported account")
        state.accounts.append(account)
        state.errorMessage = nil
        if setActiveIfFirst && state.accounts.count == 1 {
            state.activeAccountId = account.id
        }
        return account
    }

    func finalizePendingIfReady(setActive: Bool) {
        finalizeSetActiveCalls.append(setActive)
        guard let pending = state.pendingLogin else { return }
        let account = nextFinalizedAccount ?? SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        state.accounts.append(account)
        state.pendingLogin = nil
        state.pendingHint = nil
        if setActive {
            state.activeAccountId = account.id
        }
    }

    func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccount? {
        finalizeDerivedCalls.append(setActiveIfFirst)
        guard let pending = state.pendingLogin else { return nil }
        if forceDerivedFinalizeToReturnNil {
            return nil
        }
        let account = nextFinalizedAccount ?? SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        state.accounts.append(account)
        state.pendingLogin = nil
        state.pendingHint = nil
        if setActiveIfFirst && state.accounts.count == 1 {
            state.activeAccountId = account.id
        }
        return account
    }

    func switchToAccount(idOrName: String) {
        switchCalls.append(idOrName)
        guard let account = state.accounts.first(where: { $0.id == idOrName || $0.name == idOrName }) else {
            return
        }
        state.activeAccountId = account.id
        state.accounts = state.accounts.map { acc in
            var copy = acc
            if copy.id == account.id {
                copy.lastUsedAt = Date()
            }
            return copy
        }
    }

    func deleteAccount(idOrName: String) {
        deleteCalls.append(idOrName)
        guard let account = state.accounts.first(where: { $0.id == idOrName || $0.name == idOrName }) else {
            return
        }
        state.accounts.removeAll(where: { $0.id == account.id })
        if state.activeAccountId == account.id {
            state.activeAccountId = nil
        }
    }

    func syncActiveSnapshot() {
        syncCalls += 1
    }

    func renameAccount(accountId: String, newName: String) {
        renameCalls.append((accountId: accountId, newName: newName))
        state.accounts = state.accounts.map { account in
            var copy = account
            if copy.id == accountId {
                copy.name = newName
            }
            return copy
        }
    }

    private func publishPendingLogin(accountName: String) {
        let pending = nextPendingLogin ?? PendingLogin(
            providerId: "codex",
            accountId: UUID().uuidString,
            accountName: accountName,
            providerHomePath: "/tmp/\(accountName)",
            expectedAuthFilePath: "/tmp/\(accountName)/auth.json"
        )
        state.pendingLogin = pending
        state.pendingHint = "Complete login, then Switcheroo will import it."
    }
}

struct EngineHarness {
    let configStore: InMemoryConfigStore
    let secureStore: InMemorySecureStore
    let fileIO: InMemoryFileIO
    let paths: InMemoryPaths
    let provider: StubProvider
    let engine: SwitcherooEngine

    init(
        config: SwitcherooConfig = SwitcherooConfig(),
        provider: StubProvider = StubProvider(),
        rootPath: String = "/tmp/switcheroo-tests"
    ) throws {
        self.configStore = InMemoryConfigStore(config: config)
        self.secureStore = InMemorySecureStore()
        self.fileIO = InMemoryFileIO()
        self.paths = InMemoryPaths(rootPath: rootPath)
        self.provider = provider
        self.engine = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: paths,
            providers: [provider]
        )
    }

    func makeApp(providerDescriptors: [ProviderDescriptor]? = nil) -> SwitcherooApp {
        SwitcherooApp(
            engine: engine,
            fileIO: fileIO,
            providers: providerDescriptors ?? [
                ProviderDescriptor(id: provider.id, displayName: provider.displayName),
            ]
        )
    }
}

func makeAccount(
    id: String = UUID().uuidString,
    name: String,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil
) -> SwitcherooAccount {
    SwitcherooAccount(id: id, name: name, createdAt: createdAt, lastUsedAt: lastUsedAt)
}

func makeProviderState(
    id: String = "codex",
    activeAccountId: String? = nil,
    accounts: [SwitcherooAccount] = [],
    activeAuthFilePathOverride: String? = nil
) -> SwitcherooProvider {
    SwitcherooProvider(
        id: id,
        activeAccountId: activeAccountId,
        accounts: accounts,
        activeAuthFilePathOverride: activeAuthFilePathOverride
    )
}

func makeAuthData(
    email: String? = nil,
    accountId: String? = nil,
    accessTokenExpiry: Date? = nil
) throws -> Data {
    var tokens: [String: Any] = [:]
    if let accessTokenExpiry {
        tokens["access_token"] = makeJWT(payload: ["exp": accessTokenExpiry.timeIntervalSince1970])
    }
    if let email {
        tokens["id_token"] = makeJWT(payload: ["email": email])
    }
    if let accountId {
        tokens["account_id"] = accountId
    }

    return try JSONSerialization.data(withJSONObject: ["tokens": tokens])
}

func makeJWT(payload: [String: Any]) -> String {
    let header: [String: Any] = ["alg": "none", "typ": "JWT"]
    let headerPart = base64URLEncode(jsonObject: header)
    let payloadPart = base64URLEncode(jsonObject: payload)
    return "\(headerPart).\(payloadPart).signature"
}

private func base64URLEncode(jsonObject: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: jsonObject)
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
