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
}
