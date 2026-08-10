import Foundation

public protocol SwitcherooConfigStoring {
    func load() throws -> SwitcherooConfig
    func save(_ config: SwitcherooConfig) throws
}

/// Backs the account auth snapshots.
///
/// Implementations must be thread-safe: the app may call any method from any
/// executor (for example, batch usage preparation reads one credential per
/// account from concurrent app activity).
public protocol SwitcherooSecureStoring: Sendable {
    func store(_ data: Data, key: String) throws
    func load(key: String) throws -> Data
    func delete(key: String) throws
    /// True when an item exists for the key. Lets callers distinguish "missing"
    /// (no pre-image needed) from a load failure (abort before mutating).
    func itemExists(key: String) throws -> Bool
}

public protocol SwitcherooFileIO {
    func fileExists(path: String) -> Bool
    /// True for files and directories (used for lock entries).
    func itemExists(path: String) -> Bool
    func readFile(path: String) throws -> Data
    /// Atomic publish: write to a unique same-directory temporary file created
    /// exclusively with mode 0600, apply `permissions` (when given) before the
    /// rename, fsync file and directory, then rename over the destination.
    func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws
    func replaceFileAtomically(_ data: Data, ifCurrentEquals expected: Data, path: String, permissions: Int?) throws -> Bool
    /// Atomically remove a destination only when its bytes equal `expected`.
    /// The destination may be absent briefly while a same-directory quarantine
    /// rename is verified.
    func removeFileAtomically(ifCurrentEquals expected: Data, path: String, quarantinePath: String) throws -> Bool
    func moveItemAtomically(from sourcePath: String, to destinationPath: String) throws
    func removeItem(path: String) throws
    /// Create a directory; throws when it already exists (exclusive creation,
    /// used by the Pi-compatible lock protocol).
    func createDirectoryExclusive(path: String) throws
    /// Create a directory chain, creating every missing component with mode 0700.
    func createDirectory(path: String, withIntermediateDirectories: Bool) throws
    func modificationDate(path: String) -> Date?
    func setModificationDate(path: String, date: Date) throws
    /// Normalize a destination path: tilde expansion plus symlink resolution of
    /// existing components, so aliased destinations compare equal.
    func canonicalDestinationPath(_ path: String) -> String
    /// Serialize a critical section across processes with an advisory exclusive
    /// lock (blocking).
    func withExclusiveLock<T>(path: String, _ body: () throws -> T) throws -> T
}

public protocol SwitcherooPaths {
    func loginHomeDirectory(providerId: String, accountId: String) throws -> String
    func removeItem(path: String) throws
    /// Directory for Switcheroo-internal state (transaction journal, lock file).
    func stateDirectoryPath() throws -> String
}

public protocol AgentProvider {
    var id: String { get }
    var displayName: String { get }

    var defaultActiveAuthFilePath: String { get }

    func prepareLogin(accountId: String, accountName: String, paths: SwitcherooPaths) throws -> PendingLogin
    func launchLoginInteractive(pending: PendingLogin) throws
}

/// Fetches live account usage for a single account from its saved credential.
///
/// Implementations must never persist, log, or embed credentials in URLs or
/// error messages. Failures are reported via `SwitcherooUsageError`.
public protocol AccountUsageFetching: Sendable {
    func fetchUsage(authData: Data, accountId: String) async throws -> SwitcherooAccountUsage
}
