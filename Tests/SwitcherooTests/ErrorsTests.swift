import XCTest
@testable import SwitcherooCore

final class SwitcherooErrorTests: XCTestCase {
    func testErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(SwitcherooError.configUnavailable.errorDescription, "Could not locate Switcheroo config.")
        XCTAssertEqual(SwitcherooError.providerNotFound(providerId: "codex").errorDescription, "Provider not found: codex.")
        XCTAssertEqual(SwitcherooError.accountNotFound.errorDescription, "Account not found.")
        XCTAssertEqual(SwitcherooError.noActiveAccount.errorDescription, "No active account.")
        XCTAssertEqual(SwitcherooError.missingAuthFile(path: "/tmp/auth.json").errorDescription, "Missing auth file at /tmp/auth.json.")
        XCTAssertEqual(SwitcherooError.invalidAuthFile(path: "/tmp/auth.json").errorDescription, "Invalid auth file at /tmp/auth.json.")
        XCTAssertEqual(SwitcherooError.secureStoreItemMissing.errorDescription, "Secure store item missing.")
        XCTAssertEqual(SwitcherooError.secureStoreFailure(message: "boom").errorDescription, "boom")
        XCTAssertEqual(SwitcherooError.providerLoginFailed(providerId: "codex", message: "exit 1").errorDescription, "codex login failed: exit 1")
    }
}
