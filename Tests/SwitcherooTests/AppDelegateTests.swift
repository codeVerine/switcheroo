import XCTest
@testable import SwitcherooMenuBar

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationDidFinishLaunchingAndPopoverCloseDoNotCrash() {
        let delegate = AppDelegate()

        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test-launch")))
        delegate.popoverDidClose(Notification(name: Notification.Name("test-close")))
    }

    func testTogglePopoverWithoutLaunchingIsAOp() {
        let delegate = AppDelegate()

        delegate.togglePopover(nil)
    }

    func testPopoverSizingUsesExpectedHeights() {
        XCTAssertEqual(AppDelegate.popoverSize(accountCount: 0).width, 310)
        XCTAssertEqual(AppDelegate.popoverSize(accountCount: 0).height, 285)
        XCTAssertEqual(AppDelegate.popoverSize(accountCount: 1).height, 123)
        XCTAssertEqual(AppDelegate.popoverSize(accountCount: 4).height, 288)
        XCTAssertEqual(AppDelegate.popoverSize(accountCount: 5).height, 288)
    }
}
