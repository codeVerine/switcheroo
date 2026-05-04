import Foundation
import SwitcherooCore

public struct MacPaths: SwitcherooPaths {
    private let fileManager: any MacFileManaging

    public init(fileManager: FileManager = .default) {
        self.fileManager = LiveMacFileManager(fileManager: fileManager)
    }

    init(fileManager: any MacFileManaging) {
        self.fileManager = fileManager
    }

    public func loginHomeDirectory(providerId: String, accountId: String) throws -> String {
        let appSupport = try fileManager.applicationSupportDirectoryURL()
        return appSupport
            .appendingPathComponent("Switcheroo", isDirectory: true)
            .appendingPathComponent("login", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .path
    }

    public func removeItem(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        try? fileManager.removeItem(atPath: expanded)
    }
}
