import AppKit
import SwiftUI

@main
struct SwitcherooMenuBarApp: App {
    @StateObject private var model = AppModel()

    init() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Switcheroo", systemImage: "arrow.left.arrow.right") {
            StatusView(model: model, onQuit: {
                NSApplication.shared.terminate(nil)
            })
        }
        .menuBarExtraStyle(.window)
    }
}
