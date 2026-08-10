import XCTest
import SwitcherooCodexProvider
import SwitcherooCore

/// Codex is the primary auth target: whole-file replacement of the active
/// auth.json with the selected opaque snapshot.
final class CodexAuthTargetAdapterTests: XCTestCase {
    func testWriteDestinationReplacesEntireFileWithSourceSnapshot() throws {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")
        let snapshot = try makeCodexAuthData(refreshToken: "refresh-codex")
        let fileIO = InMemoryFileIO()
        let path = "/tmp/codex-auth.json"
        fileIO.files[path] = Data("unrelated prior content".utf8)

        let written = try adapter.writeDestination(
            credential: nil,
            sourceAuthData: snapshot,
            destinationPath: path,
            fileIO: fileIO
        )

        XCTAssertEqual(written.writtenData, snapshot)
        XCTAssertEqual(fileIO.files[path], snapshot)
    }

    func testWriteDestinationIsOpaquePassthroughForAnyNonNullSource() throws {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")
        let opaque = Data("{\"anything\": [1, 2, 3]}".utf8)
        let fileIO = InMemoryFileIO()

        let written = try adapter.writeDestination(credential: nil, sourceAuthData: opaque, destinationPath: "/tmp/opaque.json", fileIO: fileIO)

        XCTAssertEqual(written.writtenData, opaque)
        XCTAssertEqual(fileIO.files["/tmp/opaque.json"], opaque)
    }

    func testWriteDestinationSkipsRewriteWhenDestinationAlreadyHoldsSource() throws {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")
        let snapshot = try makeCodexAuthData(refreshToken: "refresh-codex")
        let fileIO = InMemoryFileIO()
        let path = "/tmp/codex-auth.json"
        fileIO.files[path] = snapshot

        let written = try adapter.writeDestination(credential: nil, sourceAuthData: snapshot, destinationPath: path, fileIO: fileIO)

        XCTAssertEqual(written.writtenData, snapshot)
        XCTAssertTrue(fileIO.writes.isEmpty)
    }

    func testConversionRejectsEmptySource() {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")

        XCTAssertThrowsError(try adapter.convertedCredential(fromSourceAuthData: Data())) { error in
            guard case AuthTargetSyncError.unsupportedSource(let targetId, _) = error else {
                return XCTFail("Expected unsupportedSource, got \(error)")
            }
            XCTAssertEqual(targetId, "codex")
        }
    }

    func testDestinationPathUsesProviderOverrideWhenPresent() {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")

        let path = adapter.destinationAuthFilePath(forProviderState: SwitcherooProvider(
            id: "codex",
            activeAuthFilePathOverride: "/tmp/custom/auth.json"
        ))

        XCTAssertEqual(path, "/tmp/custom/auth.json")
    }

    func testDestinationPathFallsBackToDefaultWhenNoOverride() {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")

        let path = adapter.destinationAuthFilePath(forProviderState: SwitcherooProvider(id: "codex"))

        XCTAssertEqual(path, "~/.codex/auth.json")
    }
}
