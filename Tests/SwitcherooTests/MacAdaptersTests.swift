import Foundation
import XCTest
import Darwin
import Security
@testable import SwitcherooCore
@testable import SwitcherooMacAdapters

final class MacAdaptersTests: XCTestCase {
    func testMacPathsBuildsLoginDirectoryAndRemovesItems() throws {
        let fileManager = StubMacFileManager()
        let paths = MacPaths(fileManager: fileManager)
        let loginPath = try paths.loginHomeDirectory(providerId: "codex", accountId: "acc-1")
        let expected = fileManager.applicationSupportURL
            .appendingPathComponent("Switcheroo", isDirectory: true)
            .appendingPathComponent("login", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("acc-1", isDirectory: true)
            .path

        XCTAssertEqual(loginPath, expected)

        let removable = fileManager.rootURL.appendingPathComponent("remove-me.txt")
        try FileManager.default.createDirectory(at: fileManager.rootURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: removable.path, contents: Data("hello".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removable.path))

        try paths.removeItem(path: removable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))

        try paths.removeItem(path: removable.path)
    }

    func testMacConfigStoreLoadsDefaultAndRoundTripsThroughTempHome() throws {
        let fileManager = StubMacFileManager()
        let store = MacConfigStore(fileManager: fileManager)

        let initial = try store.load()
        XCTAssertNil(initial.defaultProviderId)
        XCTAssertTrue(initial.providers.isEmpty)

        let firstConfig = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                SwitcherooProvider(
                    id: "codex",
                    activeAccountId: "acc-1",
                    accounts: [makeAccount(id: "acc-1", name: "Primary")]
                ),
            ]
        )
        try store.save(firstConfig)

        let firstLoaded = try store.load()
        XCTAssertEqual(firstLoaded.defaultProviderId, "codex")
        XCTAssertEqual(firstLoaded.providers.first?.accounts.first?.name, "Primary")

        let secondConfig = SwitcherooConfig(
            defaultProviderId: "codex",
            providers: [
                SwitcherooProvider(
                    id: "codex",
                    activeAccountId: "acc-2",
                    accounts: [makeAccount(id: "acc-2", name: "Updated")]
                ),
            ]
        )
        try store.save(secondConfig)

        let secondLoaded = try store.load()
        XCTAssertEqual(secondLoaded.providers.first?.activeAccountId, "acc-2")
        XCTAssertEqual(secondLoaded.providers.first?.accounts.first?.name, "Updated")

        let configURL = fileManager.applicationSupportURL
            .appendingPathComponent("Switcheroo", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testMacKeychainSecureStoreStoreLoadUpdateAndDeleteRoundTrip() throws {
        var items: [String: Data] = [:]
        let store = MacKeychainSecureStore(
            service: "com.switcheroo.tests.\(UUID().uuidString)",
            client: MacKeychainClient(
                addItem: { query, _ in
                    let dict = query as NSDictionary
                    let account = dict[kSecAttrAccount as String] as? String ?? ""
                    if items[account] != nil {
                        return errSecDuplicateItem
                    }
                    guard let data = dict[kSecValueData as String] as? Data else {
                        return errSecParam
                    }
                    items[account] = data
                    return errSecSuccess
                },
                copyMatching: { query, item in
                    let dict = query as NSDictionary
                    let account = dict[kSecAttrAccount as String] as? String ?? ""
                    guard let data = items[account] else {
                        return errSecItemNotFound
                    }
                    item?.pointee = data as CFTypeRef
                    return errSecSuccess
                },
                updateItem: { query, attrs in
                    let dict = query as NSDictionary
                    let account = dict[kSecAttrAccount as String] as? String ?? ""
                    guard items[account] != nil else {
                        return errSecItemNotFound
                    }
                    let attrDict = attrs as NSDictionary
                    guard let data = attrDict[kSecValueData as String] as? Data else {
                        return errSecParam
                    }
                    items[account] = data
                    return errSecSuccess
                },
                deleteItem: { query in
                    let dict = query as NSDictionary
                    let account = dict[kSecAttrAccount as String] as? String ?? ""
                    guard items.removeValue(forKey: account) != nil else {
                        return errSecItemNotFound
                    }
                    return errSecSuccess
                },
                errorMessage: { status in "status \(status)" }
            )
        )
        let key = UUID().uuidString
        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)

        try store.store(firstData, key: key)
        XCTAssertEqual(try store.load(key: key), firstData)

        try store.store(secondData, key: key)
        XCTAssertEqual(try store.load(key: key), secondData)

        try store.delete(key: key)
        XCTAssertThrowsError(try store.load(key: key)) { error in
            guard case SwitcherooError.secureStoreItemMissing = error else {
                XCTFail("Expected secureStoreItemMissing, got \(error)")
                return
            }
        }
    }

    func testCodexLoginRunnerRunsFakeCodexExecutableInProcessTTY() throws {
        try withTemporaryExecutable(name: "codex", script: """
        #!/bin/sh
        exit 0
        """) {
            let runner = CodexLoginRunner(mode: .inProcessTTY)
            try runner.run(codexHomePath: "/tmp/codex-home")
        }
    }

    func testCodexLoginRunnerSurfacesNonZeroExitStatus() throws {
        try withTemporaryExecutable(name: "codex", script: """
        #!/bin/sh
        exit 7
        """) {
            let runner = CodexLoginRunner(mode: .inProcessTTY)

            XCTAssertThrowsError(try runner.run(codexHomePath: "/tmp/codex-home")) { error in
                guard case SwitcherooError.providerLoginFailed(providerId: "codex", message: "exit 7") = error else {
                    XCTFail("Expected providerLoginFailed, got \(error)")
                    return
                }
            }
        }
    }

    func testLiveMacFileManagerForwardsCoreOperations() throws {
        let manager = LiveMacFileManager(fileManager: .default)
        let appSupport = try manager.applicationSupportDirectoryURL()
        XCTAssertEqual(appSupport.lastPathComponent, "Application Support")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)

        let fileURL = nested.appendingPathComponent("file.txt")
        let replacementURL = nested.appendingPathComponent("replacement.txt")
        let movedURL = nested.appendingPathComponent("moved.txt")
        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)

        try manager.write(firstData, to: fileURL)
        try manager.write(secondData, to: replacementURL)
        XCTAssertEqual(try manager.readData(contentsOf: fileURL), firstData)

        _ = try manager.replaceItemAt(fileURL, withItemAt: replacementURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        XCTAssertEqual(try manager.readData(contentsOf: fileURL), secondData)

        try manager.moveItem(at: fileURL, to: movedURL)
        XCTAssertTrue(manager.fileExists(atPath: movedURL.path))

        try manager.removeItem(atPath: movedURL.path)
        XCTAssertFalse(manager.fileExists(atPath: movedURL.path))

        try? FileManager.default.removeItem(at: root)
    }

    private func withTemporaryExecutable<T>(name: String, script: String, body: () throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executableURL = directory.appendingPathComponent(name)
        let contents = script.trimmingCharacters(in: .newlines) + "\n"
        try contents.data(using: .utf8)!.write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let oldPath = getenv("PATH").map { String(cString: $0) }
        let newPath = directory.path + ":" + (oldPath ?? "")

        return try withEnvironment("PATH", value: newPath) {
            defer { try? FileManager.default.removeItem(at: directory) }
            return try body()
        }
    }

    private func withEnvironment<T>(_ key: String, value: String, body: () throws -> T) rethrows -> T {
        let oldValue = getenv(key).map { String(cString: $0) }
        setenv(key, value, 1)
        defer {
            if let oldValue {
                setenv(key, oldValue, 1)
            } else {
                unsetenv(key)
            }
        }

        return try body()
    }
}

final class StubMacFileManager: MacFileManaging {
    let rootURL: URL
    let applicationSupportURL: URL
    private let backing = FileManager.default

    init(rootURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)) {
        self.rootURL = rootURL
        self.applicationSupportURL = rootURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    func applicationSupportDirectoryURL() throws -> URL {
        applicationSupportURL
    }

    func fileExists(atPath path: String) -> Bool {
        backing.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try backing.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
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
        try backing.replaceItemAt(
            originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options
        )
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try backing.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(atPath path: String) throws {
        try backing.removeItem(atPath: path)
    }
}
