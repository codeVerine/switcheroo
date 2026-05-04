import XCTest
@testable import SwitcherooCodexProvider
@testable import SwitcherooCore

final class SwitcherooCoreTests: XCTestCase {
    func testLegacyConfigDecodesIntoCodexProvider() throws {
        let data = Data(
            """
            {
              "activeAccountId": "acc-1",
              "accounts": [
                {
                  "id": "acc-1",
                  "name": "Legacy",
                  "createdAt": 0
                }
              ],
              "codexAuthPath": "/tmp/auth.json"
            }
            """.utf8
        )

        let config = try JSONDecoder().decode(SwitcherooConfig.self, from: data)

        XCTAssertEqual(config.defaultProviderId, "codex")
        XCTAssertEqual(config.providers.count, 1)

        let provider = try XCTUnwrap(config.providers.first)
        XCTAssertEqual(provider.id, "codex")
        XCTAssertEqual(provider.activeAccountId, "acc-1")
        XCTAssertEqual(provider.accounts.count, 1)
        XCTAssertEqual(provider.activeAuthFilePathOverride, "/tmp/auth.json")
    }

    func testAuthParsingSummarizesClaims() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try makeAuthData(
            email: "dev@example.com",
            accountId: "acct-123",
            accessTokenExpiry: expiry
        )

        let summary = try XCTUnwrap(CodexAuthParsing.summarize(authJSONData: data))

        XCTAssertEqual(summary.email, "dev@example.com")
        XCTAssertEqual(summary.accountId, "acct-123")
        XCTAssertEqual(summary.accessTokenExpiry?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 0.5)
    }

    func testAuthParsingReturnsNilForInvalidJSON() {
        XCTAssertNil(CodexAuthParsing.summarize(authJSONData: Data("not-json".utf8)))
    }

    func testCodexProviderPreparesLoginAndLaunchesRunner() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        final class LaunchRecorder: @unchecked Sendable {
            var path: String?
        }

        let recorder = LaunchRecorder()
        let provider = CodexProvider { recorder.path = $0 }
        let paths = InMemoryPaths(rootPath: tempRoot.path)

        let pending = try provider.prepareLogin(
            accountId: "acc-1",
            accountName: "Personal",
            paths: paths
        )

        XCTAssertEqual(pending.providerId, "codex")
        XCTAssertEqual(pending.accountId, "acc-1")
        XCTAssertEqual(pending.accountName, "Personal")
        XCTAssertEqual(pending.providerHomePath, "\(tempRoot.path)/login/codex/acc-1")
        XCTAssertEqual(pending.expectedAuthFilePath, "\(tempRoot.path)/login/codex/acc-1/auth.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.providerHomePath))

        try provider.launchLoginInteractive(pending: pending)

        XCTAssertEqual(recorder.path, pending.providerHomePath)
    }
}
