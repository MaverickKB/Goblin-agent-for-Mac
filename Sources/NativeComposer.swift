import AppKit
import SwiftUI

@MainActor
final class ComposerTextView: NSTextView {
    var submit: (() -> Void)?
    var commandReturnAction: (() -> Void)?
    var attachFiles: (([URL]) -> Void)?
    var pasteDirectory = FileManager.default.temporaryDirectory

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let text = accessibilityValue as? String else {
            super.setAccessibilityValue(accessibilityValue)
            return
        }
        string = text
        didChangeText()
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let urls = ComposerPaste.attachmentURLs(from: pasteboard, directory: pasteDirectory)
        if !urls.isEmpty {
            attachFiles?(urls)
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let commandReturn = event.modifierFlags.contains(.command)
        let plainReturn = !event.modifierFlags.contains(.shift) && !commandReturn
        if isReturn && plainReturn {
            submit?()
            return
        }
        if isReturn && commandReturn {
            commandReturnAction?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var commandReturn: () -> Void = {}
    var identifier = "chat-composer"
    var attachFiles: ([URL]) -> Void = { _ in }
    var pasteDirectory = FileManager.default.temporaryDirectory
    let submit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let editor = ComposerTextView()
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.identifier = NSUserInterfaceItemIdentifier(identifier)
        editor.setAccessibilityIdentifier(identifier)
        editor.commandReturnAction = commandReturn
        editor.setAccessibilityLabel(label)
        editor.delegate = context.coordinator
        editor.submit = submit
        editor.attachFiles = attachFiles
        editor.pasteDirectory = pasteDirectory
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.submit = submit
        editor.commandReturnAction = commandReturn
        editor.attachFiles = attachFiles
        editor.pasteDirectory = pasteDirectory
        editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer

        init(_ parent: NativeComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
