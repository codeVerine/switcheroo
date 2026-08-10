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
}

public protocol SwitcherooFileIO {
    func fileExists(path: String) -> Bool
    func readFile(path: String) throws -> Data
    func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws
}

public protocol SwitcherooPaths {
    func loginHomeDirectory(providerId: String, accountId: String) throws -> String
    func removeItem(path: String) throws
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
