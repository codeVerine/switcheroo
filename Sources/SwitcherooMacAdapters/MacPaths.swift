import Foundation
import SwitcherooCore

public struct MacPaths: SwitcherooPaths {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func loginHomeDirectory(providerId: String, accountId: String) throws -> String {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SwitcherooError.configUnavailable
        }

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

