import Foundation

public protocol SwitcherooConfigStoring {
    func load() throws -> SwitcherooConfig
    func save(_ config: SwitcherooConfig) throws
}

public protocol SwitcherooSecureStoring {
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
