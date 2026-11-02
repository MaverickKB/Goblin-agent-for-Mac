import AppKit
import SwiftUI

@main
enum GoblinMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            let resources = try locateResources()
            let product = try Product.load(from: resources)
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let home = support.appendingPathComponent(product.name)
            let delegate = try GoblinAppDelegate(product: product, resources: resources, home: home)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func locateResources() throws -> URL {
        if let resources = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: resources.appendingPathComponent("product.json").path) {
            return resources
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("product.json").path) { return root }
        throw GoblinError(message: "Product resources are missing.")
    }
}

enum CompanionLayout {
    static let figureColumnWidth: CGFloat = 240
    static let figureWidth: CGFloat = 208
    static let figureHeight: CGFloat = 300
    static let boardWidth: CGFloat = 620
    static let boardHeight: CGFloat = 650
    static let composerHeight: CGFloat = 160
    static let gap: CGFloat = 14
    static let padding: CGFloat = 12

    static var expandedSize: NSSize {
        NSSize(width: figureColumnWidth + gap + boardWidth + padding * 2,
               height: boardHeight + padding * 2)
    }

    static var collapsedSize: NSSize {
        NSSize(width: figureColumnWidth + padding * 2, height: 600)
    }
}

final class CompanionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class GoblinAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: ProfileCoordinator
    private let product: Product
    private let helpRoot: URL
    private var helpWindow: NSWindow?
    private var profilePicker: NSWindow?
    private var pendingRecall: (profile: GoblinProfile, here: Bool)?
    private var terminating = false

    init(product: Product, resources: URL, home: URL) throws {
        self.product = product
        helpRoot = resources.appendingPathComponent(Bundle.main.bundleURL.pathExtension == "app" ? "Help" : "Resources/Help")
        let catalog = ProfileCatalog(applicationHome: home)
        coordinator = ProfileCoordinator(catalog: catalog) { profile in
            let defaults: UserDefaults
            if profile == .defaultProfile { defaults = .standard }
            else {
                guard let scoped = UserDefaults(suiteName: product.bundleID + ".profile." + profile.id) else {
                    throw GoblinError(message: "Profile preferences could not be opened.")
                }
                defaults = scoped
            }
            return try GoblinStore(product: product, resources: resources, home: catalog.home(for: profile),
                                   applicationHome: home, profileID: profile.id, defaults: defaults)
        }
        super.init()
        _ = try coordinator.retainStore(for: .defaultProfile)
        coordinator.showProfiles = { [weak self] controller in self?.showProfiles(in: controller) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do { try coordinator.present(.defaultProfile) }
        catch { showStartupError(error) }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit " + product.name, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Goblin profiles…", action: #selector(profilesAction), keyEquivalent: "n")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Open chat", action: #selector(chatAction), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Collapse chat", action: #selector(collapseAction), keyEquivalent: "w")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: product.name + " Help", action: #selector(helpAction), keyEquivalent: "?")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = menu
    }

    @objc private func helpAction() {
        if helpWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = product.name + " Help"
            panel.contentView = NSHostingView(rootView: HelpView(root: helpRoot))
            panel.isReleasedWhenClosed = false
            panel.center()
            helpWindow = panel
        }
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsAction() { coordinator.focusedWindow?.showSettings() }
    @objc private func chatAction() { coordinator.focusedWindow?.showChat() }
    @objc private func collapseAction() { coordinator.focusedWindow?.collapseChat() }
    @objc private func profilesAction() {
        if let controller = coordinator.focusedWindow { showProfiles(in: controller) }
    }

    private func showProfiles(in controller: CompanionWindowController) {
        if let profilePicker { profilePicker.makeKeyAndOrderFront(nil); return }
        guard let window = controller.window else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Goblin profiles"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ProfilePickerView(
            coordinator: coordinator, current: controller, defaultName: product.name,
            dismiss: { [weak self] in self?.dismissProfiles() },
            onRecall: { [weak self] profile, here in
                self?.pendingRecall = (profile, here)
                self?.dismissProfiles()
            }))
        profilePicker = panel
        window.beginSheet(panel) { [weak self, weak controller] _ in
            guard let self else { return }
            panel.orderOut(nil)
            self.profilePicker = nil
            if let selection = self.pendingRecall {
                self.pendingRecall = nil
                do { try self.coordinator.present(selection.profile, in: selection.here ? controller : nil) }
                catch { controller?.store?.error = error.localizedDescription }
            }
        }
    }

    private func dismissProfiles() {
        guard let panel = profilePicker else { return }
        panel.sheetParent?.endSheet(panel)
    }

    private func showStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to open Goblin"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func applicationDidBecomeActive(_ notification: Notification) { coordinator.applicationActivationChanged(true) }

    func applicationDidResignActive(_ notification: Notification) {
        coordinator.releasePushToTalk()
        coordinator.applicationActivationChanged(false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = coordinator.focusedWindow {
            if controller.store?.isCollapsed == true { controller.showChat() }
            else { controller.focus() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        Task {
            await coordinator.shutdownAll()
            await KeychainBridge.waitUntilIdle()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
