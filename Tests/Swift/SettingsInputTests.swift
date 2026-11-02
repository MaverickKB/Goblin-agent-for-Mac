import AppKit
import SwiftUI
import XCTest
@testable import Goblin

final class SettingsInputTests: XCTestCase {
    @MainActor
    func testAccessibilityAndTypedEditsReachTheSameBinding() {
        var value = "initial"
        let binding = Binding<String>(get: { value }, set: { value = $0 })
        let input = SettingsTextInput(text: binding, label: "Setting", identifier: "setting")
        let coordinator = SettingsTextInput.Coordinator(input)
        let field = SettingsInput(frame: .zero)
        field.valueChanged = { value = $0 }
        field.setAccessibilityValue("accessible edit")
        XCTAssertEqual(value, "accessible edit")
        XCTAssertEqual(field.stringValue, value)
        field.stringValue = "typed edit"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(value, "typed edit")
        field.isEnabled = false
        field.setAccessibilityValue("not loaded")
        XCTAssertEqual(value, "typed edit")
    }

    @MainActor
    func testPressCanFocusTheRealNativeInput() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = SettingsInput(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        field.isEditable = true
        window.contentView?.addSubview(field)
        XCTAssertTrue(field.accessibilityPerformPress())
        let editor = field.currentEditor()
        let responderIsField = window.firstResponder === field
        let responderIsEditor = editor != nil && window.firstResponder === editor
        XCTAssertTrue(responderIsField || responderIsEditor)
    }
}
