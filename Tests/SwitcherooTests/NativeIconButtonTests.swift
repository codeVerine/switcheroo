import AppKit
import XCTest
import SwiftUI
@testable import SwitcherooMenuBar

@MainActor
final class NativeIconButtonTests: XCTestCase {
    func testNativeIconButtonCoordinatorAndHoverButtonBehave() throws {
        var hovering = false
        var actionCount = 0
        let button = NativeIconButton(
            systemName: "plus",
            tooltip: "Add",
            symbolPointSize: 13,
            foregroundColor: .white,
            backgroundColor: .black,
            isHovering: Binding(
                get: { hovering },
                set: { hovering = $0 }
            ),
            action: {
                actionCount += 1
            }
        )

        let coordinator = button.makeCoordinator()
        coordinator.performAction()
        XCTAssertEqual(actionCount, 1)

        coordinator.updateHoverState(true)
        XCTAssertTrue(hovering)
        coordinator.updateHoverState(false)
        XCTAssertFalse(hovering)

        let hoverButton = HoverButton(frame: .zero)
        var hoverEvents: [Bool] = []
        hoverButton.onHoverChanged = { hoverEvents.append($0) }
        hoverButton.updateTrackingAreas()

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )

        hoverButton.mouseEntered(with: event)
        hoverButton.mouseExited(with: event)

        XCTAssertEqual(hoverEvents, [true, false])
        XCTAssertGreaterThanOrEqual(hoverButton.trackingAreas.count, 1)
    }

    func testDisabledNativeIconButtonDisablesNSButtonAndSuppressesAction() throws {
        var hovering = false
        var actionCount = 0
        let button = NativeIconButton(
            systemName: "tray.and.arrow.down",
            tooltip: "Import logged-in account",
            symbolPointSize: 13,
            foregroundColor: .secondary,
            backgroundColor: .clear,
            isEnabled: false,
            isHovering: Binding(
                get: { hovering },
                set: { hovering = $0 }
            ),
            action: {
                actionCount += 1
            }
        )

        let coordinator = button.makeCoordinator()
        coordinator.performAction()
        XCTAssertEqual(actionCount, 0)

        let host = NSHostingView(rootView: button.frame(width: 24, height: 24))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        host.layoutSubtreeIfNeeded()

        let nsButton = try XCTUnwrap(firstButton(in: host))
        XCTAssertFalse(nsButton.isEnabled)
    }

    private func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton {
            return button
        }

        for subview in view.subviews {
            if let button = firstButton(in: subview) {
                return button
            }
        }

        return nil
    }
}
