import XCTest
@testable import SwitcherooMenuBar

@MainActor
final class SwitcherooMenuBarAppTests: XCTestCase {
    func testAppInitializesMenuBarDefaults() {
        _ = SwitcherooMenuBarApp()

        XCTAssertEqual(UserDefaults.standard.object(forKey: "NSInitialToolTipDelay") as? Int, 200)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
    }
}
