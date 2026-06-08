import AppKit
import SwiftUI

struct NativeIconButton: NSViewRepresentable {
    let systemName: String
    let tooltip: String
    let symbolPointSize: CGFloat
    let foregroundColor: Color
    let backgroundColor: Color
    var isEnabled = true
    @Binding var isHovering: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, isEnabled: isEnabled, isHovering: $isHovering)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)

        let button = HoverButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.title = ""
        button.toolTip = tooltip
        button.isEnabled = isEnabled
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.contentTintColor = NSColor(foregroundColor)
        button.layer?.backgroundColor = NSColor(backgroundColor).cgColor
        button.image = symbolImage()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.onHoverChanged = { [weak coordinator = context.coordinator] hovering in
            coordinator?.updateHoverState(hovering)
        }

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.button = button
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isHovering = $isHovering

        guard let button = context.coordinator.button else {
            return
        }

        button.toolTip = tooltip
        button.isEnabled = isEnabled
        button.contentTintColor = NSColor(foregroundColor)
        button.layer?.backgroundColor = NSColor(backgroundColor).cgColor
        button.image = symbolImage()
        button.onHoverChanged = { [weak coordinator = context.coordinator] hovering in
            coordinator?.updateHoverState(hovering)
        }
    }

    private func symbolImage() -> NSImage? {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip)
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        return image?.withSymbolConfiguration(configuration)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var isEnabled: Bool
        var isHovering: Binding<Bool>
        weak var button: HoverButton?

        init(action: @escaping () -> Void, isEnabled: Bool, isHovering: Binding<Bool>) {
            self.action = action
            self.isEnabled = isEnabled
            self.isHovering = isHovering
        }

        @objc func performAction() {
            guard isEnabled else { return }
            action()
        }

        func updateHoverState(_ hovering: Bool) {
            guard isHovering.wrappedValue != hovering else {
                return
            }

            isHovering.wrappedValue = hovering
        }
    }
}

final class HoverButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}
