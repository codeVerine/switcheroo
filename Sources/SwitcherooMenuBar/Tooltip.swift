import AppKit
import SwiftUI

// SwiftUI's `.help(...)` can be flaky in NSPopover-hosted views.
// This forces an AppKit tooltip (`NSView.toolTip`) on the hovered region.

struct TooltipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.toolTip = text
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        // The representable needs a non-zero layout region to attach the tooltip to.
        overlay(
            TooltipArea(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        )
    }
}
