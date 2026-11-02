import AppKit

@MainActor
final class CompanionWindowController: NSWindowController, NSWindowDelegate {
    private weak var coordinator: ProfileCoordinator?
    private(set) var profile: GoblinProfile?
    private(set) var store: GoblinStore?
    private var restoringFrame = false

    init(coordinator: ProfileCoordinator) {
        self.coordinator = coordinator
        let window = CompanionWindow(contentRect: NSRect(origin: .zero, size: CompanionLayout.expandedSize),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        super.init(window: window)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    private var frameName: String {
        guard let profile, profile != .defaultProfile else { return "Companion" }
        return "Companion." + profile.id
    }

    func present(profile: GoblinProfile, store: GoblinStore) {
        guard let window, let coordinator else { return }
        if let outgoing = self.store {
            window.saveFrame(usingName: frameName)
            outgoing.pushToTalk.release()
            outgoing.showChat = nil
            outgoing.collapseChat = nil
            outgoing.showSettings = nil
            outgoing.showProfiles = nil
            outgoing.selectProfile = nil
            outgoing.preferences.windowLevelChanged = nil
            outgoing.presentationWindow = nil
        }
        self.profile = profile
        self.store = store
        window.title = store.name
        window.contentView = coordinator.contentView(for: profile, store: store)
        store.presentationWindow = window
        store.showChat = { [weak self] in
            guard self?.profile == profile else { return }
            self?.showChat()
        }
        store.collapseChat = { [weak self] in
            guard self?.profile == profile else { return }
            self?.collapseChat()
        }
        store.showSettings = { [weak self] in
            guard self?.profile == profile else { return }
            self?.showSettings()
        }
        store.showProfiles = { [weak self] in
            guard let self, self.profile == profile else { return }
            self.coordinator?.showProfiles?(self)
        }
        store.selectProfile = { [weak self] id, newWindow in
            guard let self, self.profile == profile, let coordinator = self.coordinator else { return }
            do { try coordinator.present(GoblinProfile(id: id), in: newWindow ? nil : self) }
            catch { self.store?.error = error.localizedDescription }
        }
        store.preferences.windowLevelChanged = { [weak self] in
            guard self?.profile == profile else { return }
            self?.coordinator?.updateWindowLevels()
        }
        restoringFrame = true
        window.setFrameAutosaveName("")
        let restored = window.setFrameUsingName(frameName)
        if !restored, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - CompanionLayout.expandedSize.width / 2,
                                          y: visible.minY + 24))
        }
        window.setFrameAutosaveName(frameName)
        restoringFrame = false
        resizeCompanion()
    }

    func focus() {
        fitToScreen()
        coordinator?.didFocus(self)
        if let sheet = window?.attachedSheet { sheet.makeKeyAndOrderFront(nil) }
        else { window?.makeKeyAndOrderFront(nil) }
    }

    func showChat() {
        store?.settingsVisible = false
        store?.isCollapsed = false
        resizeCompanion()
        focus()
    }

    func showSettings() {
        store?.isCollapsed = false
        store?.settingsVisible = true
        resizeCompanion()
        focus()
    }

    func collapseChat() {
        store?.settingsVisible = false
        store?.isCollapsed = true
        resizeCompanion()
    }

    private func resizeCompanion() {
        guard let store, let window else { return }
        let size = store.isCollapsed ? CompanionLayout.collapsedSize : CompanionLayout.expandedSize
        let proposed = NSRect(origin: window.frame.origin, size: size)
        let frame = WindowPlacement.fitted(proposed, screens: NSScreen.screens.map { $0.visibleFrame })
        let animate = store.preferences.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animate)
        coordinator?.updateWindowLevels()
    }

    private func fitToScreen() {
        guard let window else { return }
        let frame = WindowPlacement.fitted(window.frame, screens: NSScreen.screens.map { $0.visibleFrame })
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    func windowDidMove(_ notification: Notification) {
        if !restoringFrame { window?.saveFrame(usingName: frameName) }
    }

    func windowDidBecomeKey(_ notification: Notification) { coordinator?.didFocus(self) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        coordinator?.updateWindowLevels()
        return false
    }
}
