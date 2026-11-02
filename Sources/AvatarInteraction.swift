import AppKit
import SwiftUI

@MainActor
final class AvatarControl: NSView {
    var clicked: (() -> Void)?
    var holdBegan: (() -> Void)?
    var holdEnded: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var pushToTalk = false

    private var pointerDown = false
    private var dragging = false
    private var holding = false
    private var startPoint = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var holdTask: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if resignObserver != nil { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPress() }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        cancelPress()
        guard let window else { return }
        pointerDown = true
        startPoint = window.convertPoint(toScreen: event.locationInWindow)
        startOrigin = window.frame.origin
        if !pushToTalk { return }
        holdTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, self.pointerDown, !self.dragging, self.pushToTalk else { return }
            self.holding = true
            self.holdBegan?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointerDown, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = point.x - startPoint.x
        let deltaY = point.y - startPoint.y
        if !dragging {
            if abs(deltaX) < 4 && abs(deltaY) < 4 { return }
            dragging = true
            holdTask?.cancel()
            holdTask = nil
            endHold()
        }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = pointerDown && !dragging && !pushToTalk
        let shouldOpen = pointerDown && !dragging && pushToTalk && event.clickCount == 2
        cancelPress()
        if shouldClick || shouldOpen { clicked?() }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelPress()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPress()
        return contextMenu?()
    }

    override func accessibilityPerformPress() -> Bool {
        clicked?()
        return true
    }

    func cancelPress() {
        holdTask?.cancel()
        holdTask = nil
        pointerDown = false
        dragging = false
        endHold()
    }

    private func endHold() {
        if !holding { return }
        holding = false
        holdEnded?()
    }

    func detach() {
        cancelPress()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

@MainActor
struct AvatarInteraction: NSViewRepresentable {
    let store: GoblinStore

    func makeNSView(context: Context) -> AvatarControl {
        let control = AvatarControl()
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        control.setAccessibilityIdentifier("goblin-avatar")
        return control
    }

    func updateNSView(_ control: AvatarControl, context: Context) {
        if control.pushToTalk != store.preferences.pushToTalk { control.cancelPress() }
        control.pushToTalk = store.preferences.pushToTalk
        control.clicked = { store.toggleChat() }
        control.holdBegan = { store.pushToTalk.press() }
        control.holdEnded = { store.pushToTalk.release() }
        control.contextMenu = { CompanionMenu.make(store: store) }
        control.setAccessibilityLabel("Companion. Open or collapse chat")
        control.setAccessibilityHelp(store.preferences.pushToTalk
            ? "Hold to talk. Release to mute. Drag to move. Double click for chat."
            : "Click for chat. Drag to move. Right click for options.")
    }

    static func dismantleNSView(_ control: AvatarControl, coordinator: ()) {
        control.detach()
    }
}

@MainActor
private final class CompanionMenuAction: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func runAction() { action() }
}

@MainActor
enum CompanionMenu {
    static func make(store: GoblinStore) -> NSMenu {
        let menu = NSMenu()
        add(store.isCollapsed ? "Open chat" : "Collapse chat", to: menu) { store.toggleChat() }
        add("Settings…", to: menu) { store.showSettings?() }
        menu.addItem(.separator())
        add("Always on top", to: menu, selected: store.preferences.alwaysOnTop) {
            store.preferences.alwaysOnTop.toggle()
        }
        add("Animations", to: menu, selected: store.preferences.animations) {
            store.preferences.animations.toggle()
        }
        add("Hold to talk", to: menu, selected: store.preferences.pushToTalk) {
            store.preferences.pushToTalk.toggle()
        }
        let avatars = NSMenu()
        for avatar in store.avatars {
            add(avatar.name, to: avatars, selected: store.selectedAvatar == avatar.id) {
                store.chooseAvatar(avatar.id)
            }
        }
        avatars.addItem(.separator())
        add("Import custom avatar…", to: avatars) { store.importAvatar() }
        let avatarItem = NSMenuItem(title: "Avatar", action: nil, keyEquivalent: "")
        avatarItem.submenu = avatars
        menu.addItem(avatarItem)
        add(store.autonomous ? "Pause Autonomy" : "Start Autonomy", to: menu) {
            Task { await store.setAutonomy(!store.autonomous) }
        }
        if store.busy { add("Stop", to: menu) { Task { await store.stop() } } }
        menu.addItem(.separator())
        add("Quit " + store.product.name, to: menu) { NSApp.terminate(nil) }
        return menu
    }

    private static func add(_ title: String, to menu: NSMenu, selected: Bool = false, action: @escaping () -> Void) {
        let handler = CompanionMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(CompanionMenuAction.runAction), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        item.state = selected ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(item)
    }
}
