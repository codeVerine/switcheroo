import Foundation
import SwitcherooCore

protocol MacFileManaging {
    func applicationSupportDirectoryURL() throws -> URL
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func readData(contentsOf url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL?
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(atPath path: String) throws
}

struct LiveMacFileManager: MacFileManaging {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func applicationSupportDirectoryURL() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SwitcherooError.configUnavailable
        }
        return appSupport
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }

    func readData(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL? {
        try fileManager.replaceItemAt(
            originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options
        )
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try fileManager.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(atPath path: String) throws {
        try fileManager.removeItem(atPath: path)
    }
}
