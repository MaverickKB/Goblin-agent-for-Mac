import AppKit
import SwiftUI

@MainActor
struct AccessibleButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let enabled: Bool
    var symbol: String? = nil
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.toolTip = title
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}
