import Foundation
import XCTest
@testable import SwitcherooCore

final class FoundationFileIOTests: XCTestCase {
    func testWriteReadAndFileExistsRoundTrip() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("nested/auth.json")
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        XCTAssertFalse(fileIO.fileExists(path: fileURL.path))

        let firstData = Data("first".utf8)
        try fileIO.writeFileAtomically(firstData, path: fileURL.path, permissions: 0o600)
        XCTAssertTrue(fileIO.fileExists(path: fileURL.path))
        XCTAssertEqual(try fileIO.readFile(path: fileURL.path), firstData)

        let secondData = Data("second".utf8)
        try fileIO.writeFileAtomically(secondData, path: fileURL.path, permissions: nil)
        XCTAssertEqual(try fileIO.readFile(path: fileURL.path), secondData)
    }

    func testReplaceFileAtomicallyRequiresExpectedContent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("auth.json")
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let expected = Data("expected".utf8)
        let replacement = Data("replacement".utf8)
        try fileIO.writeFileAtomically(expected, path: fileURL.path, permissions: 0o600)

        XCTAssertFalse(try fileIO.replaceFileAtomically(replacement, ifCurrentEquals: Data("other".utf8), path: fileURL.path, permissions: 0o600))
        XCTAssertEqual(try fileIO.readFile(path: fileURL.path), expected)
        XCTAssertTrue(try fileIO.replaceFileAtomically(replacement, ifCurrentEquals: expected, path: fileURL.path, permissions: 0o600))
        XCTAssertEqual(try fileIO.readFile(path: fileURL.path), replacement)
    }

    func testRemoveFileAtomicallyRequiresExpectedContent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("auth.json")
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let expected = Data("expected".utf8)
        try fileIO.writeFileAtomically(expected, path: fileURL.path, permissions: 0o600)

        let quarantinePath = "\(fileURL.path).quarantine"
        XCTAssertFalse(try fileIO.removeFileAtomically(ifCurrentEquals: Data("other".utf8), path: fileURL.path, quarantinePath: quarantinePath))
        XCTAssertTrue(fileIO.fileExists(path: fileURL.path))
        XCTAssertTrue(try fileIO.removeFileAtomically(ifCurrentEquals: expected, path: fileURL.path, quarantinePath: quarantinePath))
        XCTAssertFalse(fileIO.fileExists(path: fileURL.path))
    }

    func testWriteCreatesFilesAndDirectoriesWithUserOnlyPermissionsUnderPermissiveUmask() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("agent/subdir/auth.json")
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let previousUmask = umask(0o022)
        defer { umask(previousUmask) }

        try fileIO.writeFileAtomically(Data("credentials".utf8), path: fileURL.path, permissions: 0o600)

        // The published file must be 0600 even though the process umask is
        // permissive: the temp file is created 0600 before any bytes are written.
        let fileMode = try XCTUnwrap(modeOf(fileURL.path))
        XCTAssertEqual(fileMode & 0o777, 0o600)
        let dirMode = try XCTUnwrap(modeOf(fileURL.deletingLastPathComponent().path))
        XCTAssertEqual(dirMode & 0o777, 0o700)
        let parentMode = try XCTUnwrap(modeOf(tempRoot.appendingPathComponent("agent").path))
        XCTAssertEqual(parentMode & 0o777, 0o700)
    }

    func testWriteLeavesNoTemporaryFilesBehind() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        for index in 0..<8 {
            let fileURL = tempRoot.appendingPathComponent("auth\(index).json")
            try fileIO.writeFileAtomically(Data("data\(index)".utf8), path: fileURL.path, permissions: 0o600)
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
            .filter { $0.hasPrefix(".switcheroo.") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary files left behind: \(leftovers)")
    }

    func testPermissionFailureFailsTheWriteWithoutPublishingOrLeavingTempFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("auth.json")
        let fileIO = FoundationFileIO(fileManager: .default, permissionSetter: { _, _ in
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected permission failure"])
        })

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        XCTAssertThrowsError(try fileIO.writeFileAtomically(Data("credentials".utf8), path: fileURL.path, permissions: 0o600))

        XCTAssertFalse(fileIO.fileExists(path: fileURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
            .filter { $0.hasPrefix(".switcheroo.") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary files left behind: \(leftovers)")
    }

    func testCanonicalDestinationPathResolvesSymlinkAliases() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realDir = tempRoot.appendingPathComponent("real", isDirectory: true)
        let aliasDir = tempRoot.appendingPathComponent("alias", isDirectory: true)
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: realDir)

        let viaReal = realDir.appendingPathComponent("auth.json").path
        let viaAlias = aliasDir.appendingPathComponent("auth.json").path

        XCTAssertEqual(fileIO.canonicalDestinationPath(viaReal), fileIO.canonicalDestinationPath(viaAlias))
    }

    func testExclusiveLockSerializesAcrossFileIOInstances() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockPath = tempRoot.appendingPathComponent("switch.lock").path
        let fileIO = FoundationFileIO()

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let counter = Counter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "lock-race", attributes: .concurrent)

        for _ in 0..<8 {
            group.enter()
            queue.async {
                try? fileIO.withExclusiveLock(path: lockPath) {
                    counter.mutex.lock()
                    counter.concurrentEntries += 1
                    counter.maxConcurrentEntries = max(counter.maxConcurrentEntries, counter.concurrentEntries)
                    counter.mutex.unlock()
                    Thread.sleep(forTimeInterval: 0.01)
                    counter.mutex.lock()
                    counter.concurrentEntries -= 1
                    counter.mutex.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(counter.maxConcurrentEntries, 1)
    }

    private final class Counter: @unchecked Sendable {
        let mutex = NSLock()
        var concurrentEntries = 0
        var maxConcurrentEntries = 0
    }

    private func modeOf(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? NSNumber else {
            return nil
        }
        return mode.intValue
    }
}
