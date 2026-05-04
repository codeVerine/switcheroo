import Foundation
import SwitcherooCore

public final class MacConfigStore: @unchecked Sendable, SwitcherooConfigStoring {
    private let fileManager: any MacFileManaging
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = LiveMacFileManager(fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    init(fileManager: any MacFileManaging) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    private func configURL() throws -> URL {
        let appSupport = try fileManager.applicationSupportDirectoryURL()
        return appSupport
            .appendingPathComponent("Switcheroo", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    public func load() throws -> SwitcherooConfig {
        let url = try configURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return SwitcherooConfig()
        }
        let data = try fileManager.readData(contentsOf: url)
        return try decoder.decode(SwitcherooConfig.self, from: data)
    }

    public func save(_ config: SwitcherooConfig) throws {
        let url = try configURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data = try encoder.encode(config)
        try atomicWrite(data: data, to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".config.json.switcheroo.tmp")
        try fileManager.write(data, to: tempURL)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
    }
}
