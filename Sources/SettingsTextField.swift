import AppKit
import SwiftUI

@MainActor
final class SettingsInput: NSTextField {
    var valueChanged: ((String) -> Void)?

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEnabled else { return }
        guard let value = accessibilityValue as? String else {
            super.setAccessibilityValue(accessibilityValue)
            return
        }
        stringValue = value
        valueChanged?(value)
    }

    override func accessibilityPerformPress() -> Bool {
        return window?.makeFirstResponder(self) ?? false
    }
}

struct SettingsTextField: View {
    let label: String
    @Binding var text: String
    let identifier: String

    init(_ label: String, text: Binding<String>, identifier: String) {
        self.label = label
        _text = text
        self.identifier = identifier
    }

    var body: some View {
        LabeledContent(label) {
            SettingsTextInput(text: $text, label: label, identifier: identifier).frame(minWidth: 120)
        }
    }
}

struct SettingsTextInput: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let identifier: String
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SettingsInput {
        let field = SettingsInput(frame: .zero)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.valueChanged = { [weak coordinator = context.coordinator] value in coordinator?.parent.text = value }
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: SettingsInput, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsTextInput
        init(_ parent: SettingsTextInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

struct SettingsTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var monospaced = false
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(label)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = enabled
        editor.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        Self.applyExternalText(text, to: editor)
    }

    static func applyExternalText(_ text: String, to editor: NSTextView) {
        if editor.string == text { return }
        let selection = editor.selectedRange()
        editor.string = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsTextEditor
        init(_ parent: SettingsTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
