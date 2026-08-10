import Foundation
import SwitcherooCodexProvider
import SwitcherooCore
import SwitcherooPresentation

final class InMemoryConfigStore: SwitcherooConfigStoring {
    var config: SwitcherooConfig
    private(set) var savedConfigs: [SwitcherooConfig] = []
    var failSaves = false

    init(config: SwitcherooConfig = SwitcherooConfig()) {
        self.config = config
    }

    func load() throws -> SwitcherooConfig {
        config
    }

    func save(_ config: SwitcherooConfig) throws {
        if failSaves {
            throw NSError(domain: "TestSupport", code: 3, userInfo: [NSLocalizedDescriptionKey: "config save failed for test"])
        }
        self.config = config
        savedConfigs.append(config)
    }
}

final class InMemorySecureStore: SwitcherooSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var storedKeysList: [String] = []
    private var loadedKeysList: [String] = []
    private var deletedKeysList: [String] = []
    var failLoadKeys: Set<String> = []
    var failStoreKeys: Set<String> = []
    var failDeleteKeys: Set<String> = []

    var allItems: [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var items: [String: Data] {
        get { allItems }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var recordedStoredKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedKeysList
    }

    var recordedLoadedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedKeysList
    }

    var recordedDeletedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deletedKeysList
    }

    var storedKeys: [String] { recordedStoredKeys }
    var loadedKeys: [String] { recordedLoadedKeys }
    var deletedKeys: [String] { recordedDeletedKeys }

    func store(_ data: Data, key: String) throws {
        guard !failStoreKeys.contains(key) else {
            throw NSError(domain: "TestSupport", code: 4, userInfo: [NSLocalizedDescriptionKey: "keychain store failed for test"])
        }
        lock.lock()
        storage[key] = data
        storedKeysList.append(key)
        lock.unlock()
    }

    func load(key: String) throws -> Data {
        lock.lock()
        loadedKeysList.append(key)
        let data = storage[key]
        lock.unlock()
        guard !failLoadKeys.contains(key) else {
            throw NSError(domain: "TestSupport", code: 5, userInfo: [NSLocalizedDescriptionKey: "keychain load failed for test"])
        }
        guard let data else {
            throw SwitcherooError.secureStoreItemMissing
        }
        return data
    }

    func delete(key: String) throws {
        guard !failDeleteKeys.contains(key) else {
            throw NSError(domain: "TestSupport", code: 6, userInfo: [NSLocalizedDescriptionKey: "keychain delete failed for test"])
        }
        lock.lock()
        storage.removeValue(forKey: key)
        deletedKeysList.append(key)
        lock.unlock()
    }

    func itemExists(key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }
}
final class InMemoryFileIO: SwitcherooFileIO {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var modificationDates: [String: Date] = [:]
    private let modificationDatesLock = NSLock()
    private(set) var readPaths: [String] = []
    private(set) var writes: [(path: String, data: Data, permissions: Int?)] = []
    private(set) var removedPaths: [String] = []
    private(set) var createdDirectories: [String] = []
    private(set) var lockPaths: [String] = []
    var failWritePaths: Set<String> = []
    var failAfterWriteOncePaths: Set<String> = []
    var failRemovePaths: Set<String> = []
    var failReadPaths: Set<String> = []
    /// Called after each successful write; lets tests simulate concurrent writers.
    var onWriteToPath: ((String) -> Void)?
    var onBeforeAtomicRemove: ((String) -> Void)?
    var onAtomicRemoveMove: ((String, String) -> Void)?

    /// Destination writes excluding the internal transaction journal.
    var publishedWrites: [(path: String, data: Data, permissions: Int?)] {
        writes.filter { !$0.path.hasSuffix("/state/transaction.json") }
    }

    /// Cross-instance lock registry so separate harnesses serialize like
    /// separate processes sharing a filesystem.
    private static let registry = LockRegistry()

    private final class LockRegistry: @unchecked Sendable {
        let mutex = NSLock()
        var heldLocks: Set<String> = []
    }

    func fileExists(path: String) -> Bool {
        files[path] != nil
    }

    func itemExists(path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func readFile(path: String) throws -> Data {
        readPaths.append(path)
        guard !failReadPaths.contains(path) else {
            throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "read failed for test"])
        }
        guard let data = files[path] else {
            throw SwitcherooError.missingAuthFile(path: path)
        }
        return data
    }

    func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws {
        guard !failWritePaths.contains(path) else {
            throw NSError(domain: "TestSupport", code: 2, userInfo: [NSLocalizedDescriptionKey: "write failed for test"])
        }
        files[path] = data
        writes.append((path: path, data: data, permissions: permissions))
        onWriteToPath?(path)
        if failAfterWriteOncePaths.remove(path) != nil {
            throw NSError(domain: "TestSupport", code: 8, userInfo: [NSLocalizedDescriptionKey: "write durability failed for test"])
        }
    }

    func replaceFileAtomically(_ data: Data, ifCurrentEquals expected: Data, path: String, permissions: Int?) throws -> Bool {
        guard files[path] == expected else { return false }
        try writeFileAtomically(data, path: path, permissions: permissions)
        return true
    }

    func removeFileAtomically(ifCurrentEquals expected: Data, path: String, quarantinePath: String) throws -> Bool {
        guard files[path] == expected else { return false }
        onBeforeAtomicRemove?(path)

        guard files[quarantinePath] == nil else { return false }
        guard let quarantinedData = files.removeValue(forKey: path) else { return false }
        files[quarantinePath] = quarantinedData
        onAtomicRemoveMove?(path, quarantinePath)

        guard let quarantinedData = files[quarantinePath] else { return false }
        guard quarantinedData == expected else {
            if files[path] == nil {
                files[path] = quarantinedData
                files.removeValue(forKey: quarantinePath)
            }
            return false
        }

        files.removeValue(forKey: quarantinePath)
        return true
    }

    func moveItemAtomically(from sourcePath: String, to destinationPath: String) throws {
        guard let data = files[sourcePath], files[destinationPath] == nil else {
            throw NSError(domain: "TestSupport", code: 9, userInfo: [NSLocalizedDescriptionKey: "atomic move failed for test"])
        }
        files.removeValue(forKey: sourcePath)
        files[destinationPath] = data
    }

    func removeItem(path: String) throws {
        guard !failRemovePaths.contains(path) else {
            throw NSError(domain: "TestSupport", code: 7, userInfo: [NSLocalizedDescriptionKey: "remove failed for test"])
        }
        files.removeValue(forKey: path)
        directories.remove(path)
        modificationDatesLock.lock()
        modificationDates.removeValue(forKey: path)
        modificationDatesLock.unlock()
        removedPaths.append(path)
    }

    func createDirectoryExclusive(path: String) throws {
        if itemExists(path: path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "directory exists"])
        }
        directories.insert(path)
        modificationDatesLock.lock()
        modificationDates[path] = Date()
        modificationDatesLock.unlock()
        createdDirectories.append(path)
    }

    func createDirectory(path: String, withIntermediateDirectories: Bool) throws {
        directories.insert(path)
        createdDirectories.append(path)
    }

    func modificationDate(path: String) -> Date? {
        modificationDatesLock.lock()
        defer { modificationDatesLock.unlock() }
        return modificationDates[path]
    }

    func setModificationDate(path: String, date: Date) throws {
        modificationDatesLock.lock()
        defer { modificationDatesLock.unlock() }
        modificationDates[path] = date
    }

    func canonicalDestinationPath(_ path: String) -> String {
        // In-memory store has no symlinks; identical spellings already compare
        // equal, so the identity mapping keeps fixture keys stable.
        path
    }

    func withExclusiveLock<T>(path: String, _ body: () throws -> T) throws -> T {
        lockPaths.append(path)
        while true {
            Self.registry.mutex.lock()
            if !Self.registry.heldLocks.contains(path) {
                Self.registry.heldLocks.insert(path)
                Self.registry.mutex.unlock()
                defer {
                    Self.registry.mutex.lock()
                    Self.registry.heldLocks.remove(path)
                    Self.registry.mutex.unlock()
                }
                return try body()
            }
            Self.registry.mutex.unlock()
            Thread.sleep(forTimeInterval: 0.001)
        }
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

    func stateDirectoryPath() throws -> String {
        "\(rootPath)/state"
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
    var onUsageUpdated: (@Sendable () -> Void)?

    private(set) var refreshTriggers: [UsageRefreshTrigger] = []
    private(set) var startAddAccountNameCalls: [String] = []
    private(set) var startAddAccountCalls = 0
    private(set) var importCurrentAccountNameCalls: [String] = []
    private(set) var importCurrentAccountDerivedCalls: [Bool] = []
    private(set) var finalizeSetActiveCalls: [Bool] = []
    private(set) var finalizeDerivedCalls: [Bool] = []
    private(set) var switchCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var syncCalls = 0
    private(set) var autoSyncDecisionCalls: [Date] = []
    private(set) var renameCalls: [(accountId: String, newName: String)] = []

    var nextPendingLogin: PendingLogin?
    var nextImportedAccount: SwitcherooAccount?
    var nextFinalizedAccount: SwitcherooAccount?
    var nextImportedDisposition: SwitcherooAccountWriteDisposition = .created
    var nextFinalizedDisposition: SwitcherooAccountWriteDisposition = .created
    var nextSnapshot: SwitcherooAppState?
    var forceDerivedImportToReturnNil = false
    var forceDerivedFinalizeToReturnNil = false
    var switchError: Error?
    var nextSyncResult = SwitcherooActiveSnapshotSyncResult(
        disposition: .updatedExisting,
        account: nil,
        accessTokenExpiry: nil
    )
    var nextAutoSyncDecision: SwitcherooAutoSyncDecision = .disabled(requiresRelogin: false)

    init(state: SwitcherooAppState = SwitcherooAppState()) {
        self.state = state
    }

    func refresh(usageTrigger: UsageRefreshTrigger) {
        refreshTriggers.append(usageTrigger)
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

    func importCurrentAccount(name: String) -> SwitcherooAccountWriteResult? {
        importCurrentAccountNameCalls.append(name)
        let account = nextImportedAccount ?? SwitcherooAccount(name: name)
        if nextImportedDisposition == .created {
            state.accounts.append(account)
        }
        state.errorMessage = nil
        if state.activeAccountId == nil && state.accounts.count == 1 {
            state.activeAccountId = account.id
        }
        return SwitcherooAccountWriteResult(disposition: nextImportedDisposition, account: account)
    }

    func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult? {
        importCurrentAccountDerivedCalls.append(setActiveIfFirst)
        if forceDerivedImportToReturnNil {
            return nil
        }
        let account = nextImportedAccount ?? SwitcherooAccount(name: "Imported account")
        if nextImportedDisposition == .created {
            state.accounts.append(account)
        }
        state.errorMessage = nil
        if setActiveIfFirst && !hasActiveAccount {
            state.activeAccountId = account.id
        }
        return SwitcherooAccountWriteResult(disposition: nextImportedDisposition, account: account)
    }

    func finalizePendingIfReady(setActive: Bool) -> SwitcherooAccountWriteResult? {
        finalizeSetActiveCalls.append(setActive)
        guard let pending = state.pendingLogin else { return nil }
        let account = nextFinalizedAccount ?? SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        if nextFinalizedDisposition == .created {
            state.accounts.append(account)
        }
        state.pendingLogin = nil
        state.pendingHint = nil
        if setActive {
            state.activeAccountId = account.id
        }
        return SwitcherooAccountWriteResult(disposition: nextFinalizedDisposition, account: account)
    }

    func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult? {
        finalizeDerivedCalls.append(setActiveIfFirst)
        guard let pending = state.pendingLogin else { return nil }
        if forceDerivedFinalizeToReturnNil {
            return nil
        }
        let account = nextFinalizedAccount ?? SwitcherooAccount(id: pending.accountId, name: pending.accountName)
        if nextFinalizedDisposition == .created {
            state.accounts.append(account)
        }
        state.pendingLogin = nil
        state.pendingHint = nil
        if setActiveIfFirst && !hasActiveAccount {
            state.activeAccountId = account.id
        }
        return SwitcherooAccountWriteResult(disposition: nextFinalizedDisposition, account: account)
    }

    func switchToAccount(idOrName: String) throws {
        switchCalls.append(idOrName)
        if let switchError {
            throw switchError
        }
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

    func syncActiveSnapshot() -> SwitcherooActiveSnapshotSyncResult? {
        syncCalls += 1
        state.requiresRelogin = nextSyncResult.requiresRelogin
        return nextSyncResult
    }

    func autoSyncDecision(now: Date) -> SwitcherooAutoSyncDecision {
        autoSyncDecisionCalls.append(now)
        state.requiresRelogin = nextAutoSyncDecision.requiresRelogin
        return nextAutoSyncDecision
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

    private var hasActiveAccount: Bool {
        guard let activeAccountId = state.activeAccountId else { return false }
        return state.accounts.contains(where: { $0.id == activeAccountId })
    }
}

/// Deterministic clock for tests: advance it instead of sleeping.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// Test double for live account-usage fetching. Handlers are registered per
/// account id; an optional per-account delay simulates slow responses.
final class MockAccountUsageFetcher: AccountUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable () async throws -> SwitcherooAccountUsage]
    private var defaultHandler: (@Sendable () async throws -> SwitcherooAccountUsage)?
    private var recordedAccountIds: [String] = []
    private var recordedAuthData: [(accountId: String, authData: Data)] = []
    private var activeCount = 0
    private var maxConcurrent = 0

    init(handlers: [String: @Sendable () async throws -> SwitcherooAccountUsage] = [:]) {
        self.handlers = handlers
    }

    func setDefaultResult(_ usage: SwitcherooAccountUsage) {
        lock.lock()
        defaultHandler = { usage }
        lock.unlock()
    }

    var callAccountIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAccountIds
    }

    /// Safe per-call fingerprint of the credential bytes each account was
    /// fetched with, so tests can prove credentials never cross accounts.
    var recordedAuthDataByAccount: [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        var byAccount: [String: Data] = [:]
        for call in recordedAuthData {
            byAccount[call.accountId] = call.authData
        }
        return byAccount
    }

    /// Highest number of fetches observed executing concurrently.
    var maxConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxConcurrent
    }

    func setResult(accountId: String, usage: SwitcherooAccountUsage) {
        setHandler(accountId: accountId) { usage }
    }

    func setError(accountId: String, error: Error) {
        setHandler(accountId: accountId) { throw error }
    }

    func setHandler(accountId: String, _ handler: @escaping @Sendable () async throws -> SwitcherooAccountUsage) {
        lock.lock()
        handlers[accountId] = handler
        lock.unlock()
    }

    func fetchUsage(authData: Data, accountId: String) async throws -> SwitcherooAccountUsage {
        let handler = beginCall(accountId: accountId, authData: authData)
        defer { endCall() }
        if let handler {
            return try await handler()
        }
        throw SwitcherooUsageError.serviceUnavailable(retryAfterSeconds: nil)
    }

    private func beginCall(accountId: String, authData: Data) -> (@Sendable () async throws -> SwitcherooAccountUsage)? {
        lock.lock()
        recordedAccountIds.append(accountId)
        recordedAuthData.append((accountId: accountId, authData: authData))
        activeCount += 1
        maxConcurrent = max(maxConcurrent, activeCount)
        let handler = handlers[accountId] ?? defaultHandler
        lock.unlock()
        return handler
    }

    private func endCall() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }
}

final class StubAuthTargetAdapter: @unchecked Sendable, AuthTargetAdapter {
    enum WriteMode {
        /// Destination becomes exactly the source snapshot (Codex semantics).
        case replaceWithSource
        /// Destination keeps every unrelated top-level entry and replaces one key.
        case upsertKey(String)
    }

    let id: String
    let displayName: String
    let defaultDestinationAuthFilePath: String
    let convertedValue: AuthTargetJSON
    var writeMode: WriteMode
    var conversionError: Error?
    var documentError: Error?
    private(set) var conversionCalls = 0
    private(set) var documentCalls = 0
    private(set) var validationCalls = 0

    init(
        id: String = "stub-target",
        displayName: String = "Stub Target",
        defaultDestinationAuthFilePath: String = "~/.stub-target/auth.json",
        destinationKey: String = "stub-credential",
        convertedValue: AuthTargetJSON = .object(["marker": .string("stub")]),
        writeMode: WriteMode = .upsertKey("stub-credential")
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultDestinationAuthFilePath = defaultDestinationAuthFilePath
        self.convertedValue = convertedValue
        self.writeMode = writeMode
    }

    func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String {
        defaultDestinationAuthFilePath
    }

    func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential? {
        conversionCalls += 1
        if let conversionError {
            throw conversionError
        }
        switch writeMode {
        case .replaceWithSource:
            return nil
        case .upsertKey(let key):
            return AuthTargetCredential(destinationKey: key, jsonValue: convertedValue)
        }
    }

    func validateExistingDestination(existingDestinationData: Data?, destinationPath: String) throws {
        validationCalls += 1
    }

    func writeDestination(credential: AuthTargetCredential?, sourceAuthData: Data, destinationPath: String, fileIO: SwitcherooFileIO) throws -> AuthTargetWriteResult {
        documentCalls += 1
        if let documentError {
            throw documentError
        }
        switch writeMode {
        case .replaceWithSource:
            let existing = fileIO.fileExists(path: destinationPath) ? try fileIO.readFile(path: destinationPath) : nil
            if existing == sourceAuthData {
                return AuthTargetWriteResult(previousData: existing, writtenData: sourceAuthData)
            }
            try fileIO.writeFileAtomically(sourceAuthData, path: destinationPath, permissions: 0o600)
            return AuthTargetWriteResult(previousData: existing, writtenData: sourceAuthData)
        case .upsertKey(let key):
            guard let credential else {
                throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "missing converted credential")
            }
            let existing = fileIO.fileExists(path: destinationPath) ? try fileIO.readFile(path: destinationPath) : nil
            let merged = try AuthTargetDocument.merging(credential, into: existing, targetId: id, destinationPath: destinationPath)
            try fileIO.writeFileAtomically(merged, path: destinationPath, permissions: 0o600)
            return AuthTargetWriteResult(previousData: existing, writtenData: merged)
        }
    }
}

struct EngineHarness {
    let configStore: InMemoryConfigStore
    let secureStore: InMemorySecureStore
    let fileIO: InMemoryFileIO
    let paths: InMemoryPaths
    let provider: StubProvider
    let authTargetAdapters: [any AuthTargetAdapter]
    let engine: SwitcherooEngine

    init(
        config: SwitcherooConfig = SwitcherooConfig(),
        provider: StubProvider = StubProvider(),
        rootPath: String = "/tmp/switcheroo-tests",
        includeCodexTarget: Bool = true,
        authTargetAdapters: [any AuthTargetAdapter] = []
    ) throws {
        self.configStore = InMemoryConfigStore(config: config)
        self.secureStore = InMemorySecureStore()
        self.fileIO = InMemoryFileIO()
        self.paths = InMemoryPaths(rootPath: rootPath)
        self.provider = provider
        var adapters = authTargetAdapters
        if includeCodexTarget {
            adapters.insert(CodexAuthTargetAdapter(defaultAuthFilePath: provider.defaultActiveAuthFilePath), at: 0)
        }
        self.authTargetAdapters = adapters
        self.engine = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: paths,
            providers: [provider],
            authTargetAdapters: adapters
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
    identityKey: String? = nil,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil
) -> SwitcherooAccount {
    SwitcherooAccount(id: id, name: name, identityKey: identityKey, createdAt: createdAt, lastUsedAt: lastUsedAt)
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

/// Codex-style auth.json with the OAuth fields auth-target adapters consume:
/// a JWT access token carrying `exp` and the `chatgpt_account_id` claim (the
/// claim Pi itself validates), a refresh token, and an id_token carrying the
/// same account claim. `accountId` matches the usage-fetching fixture shape;
/// `tokensAccountId` overrides it for auth-target fixtures.
func makeCodexAuthData(
    accessToken: String? = nil,
    accountId: String? = nil,
    refreshToken: String? = nil,
    idToken: String? = nil,
    tokensAccountId: String? = nil
) throws -> Data {
    var tokens: [String: Any] = [:]
    tokens["access_token"] = accessToken ?? makeJWT(payload: [
        "exp": 1_700_000_000,
        "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
    ])
    tokens["refresh_token"] = refreshToken ?? "test-refresh-token"
    tokens["id_token"] = idToken ?? makeJWT(payload: [
        "https://api.openai.com/auth": ["chatgpt_account_id": "chatgpt-acct-1"],
    ])
    if let accountId {
        tokens["account_id"] = accountId
    }
    if let tokensAccountId {
        tokens["account_id"] = tokensAccountId
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
