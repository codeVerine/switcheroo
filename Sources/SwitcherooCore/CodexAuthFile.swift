import Foundation

public struct CodexAuthFile {
    public static let defaultPath = "~/.codex/auth.json"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func url(forPath path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    public func readAuthData(fromPath path: String) throws -> Data {
        let url = url(forPath: path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SwitcherooError.missingCodexAuthFile(path: url.path)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw SwitcherooError.invalidCodexAuthFile(path: url.path)
        }
        return data
    }

    public func writeAuthData(_ data: Data, toPath path: String) throws {
        let url = url(forPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".auth.json.switcheroo.tmp")
        try data.write(to: tempURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func modificationDate(path: String) -> Date? {
        let url = url(forPath: path)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
