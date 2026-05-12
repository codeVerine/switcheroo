import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let logger = Logger(subsystem: "com.switcheroo", category: "menu-bar")
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit tooltips have a system-managed delay; make it feel snappier in our popover UI.
        // `register(defaults:)` is non-persistent (does not write to disk).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.left.arrow.right",
                accessibilityDescription: "Switcheroo"
            )
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = Self.popoverSize(accountCount: model.state.accounts.count)
        popover.contentViewController = NSHostingController(
            rootView: StatusView(
                model: model,
                onQuit: { [weak self] in self?.quit() }
            )
        )

        logger.info("Launched")
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            logger.error("Missing status item button")
            return
        }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        model.refresh()
        popover.contentSize = Self.popoverSize(accountCount: model.state.accounts.count)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        logger.debug("Popover closed")
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    static func popoverSize(accountCount: Int) -> NSSize {
        let height: CGFloat

        if accountCount == 0 {
            height = 285
        } else {
            let visibleRows = min(accountCount, 4)
            height = 68 + CGFloat(visibleRows) * 55
        }

        return NSSize(width: 310, height: min(height, 380))
    }
}
