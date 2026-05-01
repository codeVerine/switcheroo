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
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Switcheroo"
            )
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: StatusView(
                model: model,
                onQuit: { [weak self] in self?.quit() }
            )
        )

        logger.info("Launched")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            logger.error("Missing status item button")
            return
        }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        logger.debug("Popover closed")
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
