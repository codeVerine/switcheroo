import Foundation

public struct AppSupportPaths {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func appSupportDirectory() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SwitcherooError.configDirectoryUnavailable
        }
        return appSupport.appendingPathComponent("Switcheroo", isDirectory: true)
    }

    public func loginHomeDirectory(accountId: String) throws -> URL {
        try appSupportDirectory()
            .appendingPathComponent("login", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
    }
}
