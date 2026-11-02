import AppKit
import SwiftUI

@MainActor
final class ProfileCoordinator {
    let catalog: ProfileCatalog
    private let makeStore: (GoblinProfile) throws -> GoblinStore
    private(set) var stores: [String: GoblinStore] = [:]
    private(set) var windows: [CompanionWindowController] = []
    var showProfiles: ((CompanionWindowController) -> Void)?
    private var contentViews: [String: NSView] = [:]
    private weak var lastFocusedChat: CompanionWindowController?
    private weak var lastFocusedWindow: CompanionWindowController?
    private var shuttingDown = false
    private var applicationActive = NSApp.isActive

    init(catalog: ProfileCatalog, makeStore: @escaping (GoblinProfile) throws -> GoblinStore) {
        self.catalog = catalog
        self.makeStore = makeStore
    }

    func retainStore(for profile: GoblinProfile) throws -> GoblinStore {
        if let store = stores[profile.id] { return store }
        guard !shuttingDown else { throw GoblinError(message: "The app is quitting.") }
        let store = try makeStore(profile)
        stores[profile.id] = store
        store.profileNameChanged = { [weak self] in self?.refreshProfileChoices() }
        refreshProfileChoices()
        return store
    }

    func name(for profile: GoblinProfile, defaultName: String) -> String {
        if let store = stores[profile.id], store.settingsLoaded { return store.name }
        return catalog.name(for: profile, defaultName: defaultName)
    }

    func create(name: String) async throws -> GoblinProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GoblinError(message: "Enter a Goblin name.") }
        let profile = try catalog.prepare()
        let store = try retainStore(for: profile)
        await store.start()
        guard !shuttingDown, store.isConnected, store.settingsLoaded else {
            throw GoblinError(message: store.error.isEmpty ? "The new profile could not start." : store.error)
        }
        var settings = store.snapshot["settings"].objectValue
        settings["agent_name"] = .string(name)
        let outcome = try await store.saveSettings(settings, expectedRevision: store.settingsRevision)
        guard outcome.settingsIssue.isEmpty else { throw GoblinError(message: outcome.settingsIssue) }
        guard !shuttingDown else { throw GoblinError(message: "The app is quitting.") }
        try catalog.publish(profile)
        refreshProfileChoices()
        return profile
    }

    func refreshProfileChoices() {
        do {
            let profiles = try catalog.profiles()
            var choices: [ProfileChoice] = []
            for profile in profiles {
                let defaultName = stores.values.first?.product.name ?? profile.id
                choices.append(ProfileChoice(id: profile.id, name: name(for: profile, defaultName: defaultName)))
            }
            for store in stores.values {
                store.profileChoices = choices
                store.profileChoicesError = ""
            }
        } catch {
            for store in stores.values {
                store.profileChoices = []
                store.profileChoicesError = "Profile list could not be read: " + error.localizedDescription
            }
        }
    }

    @discardableResult
    func present(_ profile: GoblinProfile, in current: CompanionWindowController? = nil) throws -> CompanionWindowController {
        guard !shuttingDown else { throw GoblinError(message: "The app is quitting.") }
        for controller in windows where controller.profile == profile {
            controller.focus()
            return controller
        }
        if let window = current?.window {
            guard window.attachedSheet == nil else {
                throw GoblinError(message: "Finish the open sheet before switching this window to another Goblin.")
            }
            guard window.makeFirstResponder(nil) else {
                throw GoblinError(message: "Finish editing before switching this window to another Goblin.")
            }
        }
        let store = try retainStore(for: profile)
        let controller: CompanionWindowController
        if let current { controller = current }
        else {
            controller = CompanionWindowController(coordinator: self)
            windows.append(controller)
        }
        controller.present(profile: profile, store: store)
        controller.focus()
        Task { [weak self] in
            guard let self, !self.shuttingDown else { return }
            await store.start()
        }
        return controller
    }

    func contentView(for profile: GoblinProfile, store: GoblinStore) -> NSView {
        if let view = contentViews[profile.id] { return view }
        let view = NSHostingView(rootView: CompanionView(store: store).id(profile.id).defaultAppStorage(store.defaults))
        view.sizingOptions = []
        contentViews[profile.id] = view
        return view
    }

    var focusedWindow: CompanionWindowController? {
        for controller in windows where controller.window?.isKeyWindow == true { return controller }
        return lastFocusedWindow ?? windows.first
    }

    func didFocus(_ controller: CompanionWindowController) {
        lastFocusedWindow = controller
        if controller.store?.isCollapsed == false { lastFocusedChat = controller }
        updateWindowLevels(focusing: controller)
    }

    func applicationActivationChanged(_ active: Bool) {
        applicationActive = active
        updateWindowLevels()
    }

    func updateWindowLevels(focusing controller: CompanionWindowController? = nil) {
        let focusWillShowChat = controller != nil && lastFocusedChat === controller
        if lastFocusedChat?.store?.isCollapsed != false || (!focusWillShowChat && lastFocusedChat?.window?.isVisible != true) {
            lastFocusedChat = nil
            for controller in windows where controller.window?.isVisible == true && controller.store?.isCollapsed == false {
                lastFocusedChat = controller
            }
        }
        for controller in windows {
            guard let window = controller.window, let store = controller.store else { continue }
            var desired: NSWindow.Level = store.preferences.alwaysOnTop ? .floating : .normal
            if applicationActive, let protected = lastFocusedChat, controller !== protected { desired = .normal }
            if window.level != desired { window.level = desired }
        }
    }

    func releasePushToTalk() {
        for store in stores.values { store.pushToTalk.release() }
    }

    func shutdownAll() async {
        shuttingDown = true
        for store in stores.values {
            await store.voice.stop()
            await store.engine.shutdown()
        }
    }
}
