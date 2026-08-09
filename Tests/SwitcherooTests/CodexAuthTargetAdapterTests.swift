import XCTest
import SwitcherooCodexProvider
import SwitcherooCore

/// Codex is the primary auth target: whole-file replacement of the active
/// auth.json with the selected opaque snapshot.
final class CodexAuthTargetAdapterTests: XCTestCase {
    func testDestinationDocumentReplacesEntireFileWithSourceSnapshot() throws {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")
        let snapshot = try makeCodexAuthData(refreshToken: "refresh-codex")

        let document = try adapter.destinationDocument(
            fromSourceAuthData: snapshot,
            existingDestinationData: Data("unrelated prior content".utf8)
        )

        XCTAssertEqual(document, snapshot)
    }

    func testDestinationDocumentIsOpaquePassthroughForAnyNonNullSource() throws {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")
        let opaque = Data("{\"anything\": [1, 2, 3]}".utf8)

        let document = try adapter.destinationDocument(fromSourceAuthData: opaque, existingDestinationData: nil)

        XCTAssertEqual(document, opaque)
    }

    func testDestinationDocumentRejectsEmptySource() {
        let adapter = CodexAuthTargetAdapter(defaultAuthFilePath: "~/.codex/auth.json")

        XCTAssertThrowsError(try adapter.destinationDocument(fromSourceAuthData: Data(), existingDestinationData: nil)) { error in
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
