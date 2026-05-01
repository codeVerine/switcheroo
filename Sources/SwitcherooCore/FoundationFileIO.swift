import Foundation

public struct FoundationFileIO: SwitcherooFileIO {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(path: String) -> Bool {
        let url = url(forPath: path)
        return fileManager.fileExists(atPath: url.path)
    }

    public func readFile(path: String) throws -> Data {
        let url = url(forPath: path)
        return try Data(contentsOf: url)
    }

    public func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws {
        let url = url(forPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".switcheroo.tmp")
        try data.write(to: tempURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }

        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func url(forPath path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}

