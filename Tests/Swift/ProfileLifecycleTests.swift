import AppKit
import XCTest
@testable import Goblin

final class ProfileCatalogTests: XCTestCase {
    func testLegacyLocationAndPublishedIDsSurviveReloadWithoutNameOrHomeCopies() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let catalog = ProfileCatalog(applicationHome: home)
        XCTAssertEqual(try catalog.profiles(), [.defaultProfile])
        XCTAssertEqual(try catalog.home(for: .defaultProfile), home)
        let prepared = try catalog.prepare()
        XCTAssertEqual(try catalog.profiles(), [.defaultProfile], "Preparation must not publish an incomplete profile")
        let profileHome = try catalog.home(for: prepared)
        XCTAssertEqual(profileHome, home.appendingPathComponent("profiles").appendingPathComponent(prepared.id))
        try Data("{\"agent_name\":\"Original\"}".utf8).write(to: profileHome.appendingPathComponent("config.json"))
        try catalog.publish(prepared)
        try catalog.publish(prepared)
        XCTAssertEqual(try ProfileCatalog(applicationHome: home).profiles(), [.defaultProfile, prepared])
        XCTAssertEqual(catalog.name(for: prepared, defaultName: "Default"), "Original")
        try Data("{\"agent_name\":\"Renamed\"}".utf8).write(to: profileHome.appendingPathComponent("config.json"))
        XCTAssertEqual(catalog.name(for: prepared, defaultName: "Default"), "Renamed")
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("profiles.json")))
        XCTAssertEqual(document["profiles"].arrayValue[1], .object(["id": .string(prepared.id)]))
        XCTAssertThrowsError(try catalog.home(for: GoblinProfile(id: "../other")))
    }
}

@MainActor
final class ProfileLifecycleTests: XCTestCase {
    private func coordinator(refuseSave: Bool = false) throws -> ProfileCoordinator {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = ProfileCatalog(applicationHome: home)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let product = try Product.load(from: root)
        return ProfileCoordinator(catalog: catalog) { profile in
            let defaults = UserDefaults(suiteName: "GoblinProfileTests." + home.lastPathComponent + "." + profile.id)!
            let store = try GoblinStore(product: product, resources: root.appendingPathComponent("Resources"),
                                        home: catalog.home(for: profile), applicationHome: home,
                                        profileID: profile.id, defaults: defaults)
            store.preferences.animations = false
            let generation = store.beginConnection()
            store.finishConnection(Self.snapshot(name: profile.id, revision: 1), generation: generation)
            store.rpc = { method, params in
                if method == "settings/save" {
                    if refuseSave { throw GoblinError(message: "Refused settings") }
                    return Self.snapshot(name: params["settings"]?["agent_name"].stringValue ?? "", revision: 2)
                }
                return .object([:])
            }
            return store
        }
    }

    private static func snapshot(name: String, revision: Int) -> JSONValue {
        .object(["revision": .number(Double(revision)), "settings_revision": .number(Double(revision)),
                 "ready": .bool(true), "busy": .bool(false), "history_id": .string("legacy"),
                 "settings": .object(["agent_name": .string(name), "approval": .string("ask")])])
    }

    private func clean(_ coordinator: ProfileCoordinator) {
        for (id, store) in coordinator.stores {
            let domain = "GoblinProfileTests." + coordinator.catalog.applicationHome.lastPathComponent + "." + id
            store.defaults.removePersistentDomain(forName: domain)
        }
        for controller in coordinator.windows {
            controller.window?.setFrameAutosaveName("")
            controller.window?.orderOut(nil)
        }
        try? FileManager.default.removeItem(at: coordinator.catalog.applicationHome)
    }

    func testRecallRetainsOutgoingRuntimeDraftStreamAndViewGraphAndFocusesExistingWindow() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let first = try coordinator.present(.defaultProfile)
        let original = try XCTUnwrap(first.store)
        original.draft = "Keep my draft"
        original.settingsVisible = true
        original.receive("stream", .object(["text": .string("unfinished"), "response_id": .string("answer"), "kind": .string("agent")]))
        let content = first.window?.contentView
        let delayedOldShowChat = original.showChat
        let generation = original.connectionGeneration
        let secondProfile = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(secondProfile)
        let rebound = try coordinator.present(secondProfile, in: first)
        XCTAssertTrue(rebound === first)
        XCTAssertTrue(coordinator.stores["default"] === original)
        XCTAssertEqual(original.connectionGeneration, generation)
        XCTAssertEqual(original.draft, "Keep my draft")
        XCTAssertEqual(original.stream, "unfinished")
        XCTAssertNil(original.presentationWindow)
        XCTAssertFalse(first.window?.contentView === content)
        first.store?.settingsVisible = true
        delayedOldShowChat?()
        XCTAssertTrue(first.store?.settingsVisible == true, "A delayed old callback cannot relabel the newly presented profile")
        _ = try coordinator.present(.defaultProfile, in: first)
        XCTAssertTrue(first.window?.contentView === content, "Returning restores Settings @State in the same view graph")
        XCTAssertTrue(original.settingsVisible)
        let second = try coordinator.present(secondProfile)
        let focused = try coordinator.present(.defaultProfile, in: second)
        XCTAssertTrue(focused === first)
        XCTAssertEqual(second.profile, secondProfile)
        XCTAssertEqual(coordinator.windows.count, 2)
        XCTAssertEqual(coordinator.stores.count, 2)
    }

    func testOverlappingAvatarCannotRiseAboveFocusedChatThroughBackgroundUpdates() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let avatar = try coordinator.present(.defaultProfile)
        let secondProfile = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(secondProfile)
        let chat = try coordinator.present(secondProfile)
        let avatarStore = try XCTUnwrap(avatar.store)
        let chatStore = try XCTUnwrap(chat.store)
        avatarStore.preferences.alwaysOnTop = true
        avatar.collapseChat()
        chatStore.preferences.alwaysOnTop = false
        let frame = NSRect(x: 150, y: 150, width: 500, height: 600)
        avatar.window?.setFrame(frame, display: false)
        chat.window?.setFrame(frame, display: false)
        coordinator.applicationActivationChanged(true)
        chat.focus()
        XCTAssertEqual(chat.window?.level, .normal)
        XCTAssertEqual(avatar.window?.level, .normal)
        let order = NSApp.orderedWindows.map(\.windowNumber)
        avatarStore.preferences.alwaysOnTop = false
        avatarStore.preferences.alwaysOnTop = true
        avatarStore.receive("stream", .object(["text": .string("background reply"), "kind": .string("agent")]))
        coordinator.updateWindowLevels()
        XCTAssertEqual(avatar.window?.level, .normal)
        XCTAssertEqual(NSApp.orderedWindows.map(\.windowNumber), order, "Background updates must not order a window forward")
        avatar.showChat()
        XCTAssertEqual(avatar.window?.level, .floating)
        XCTAssertEqual(chat.window?.level, .normal)
        chat.focus()
        XCTAssertEqual(avatar.window?.level, .normal)
        XCTAssertEqual(chat.window?.level, .normal)
        XCTAssertTrue(coordinator.focusedWindow === chat)
        coordinator.applicationActivationChanged(false)
        XCTAssertEqual(avatar.window?.level, .floating, "Always on top is restored over other applications")
        XCTAssertEqual(chat.window?.level, .normal)
        coordinator.applicationActivationChanged(true)
        XCTAssertEqual(avatar.window?.level, .normal, "Returning to the focused chat restores cooperative levels")
    }

    func testCreateUsesExistingSettingsSaveAndPublishesOnlyOnSuccess() async throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let profile = try await coordinator.create(name: "  Unique Goblin  ")
        XCTAssertEqual(coordinator.stores[profile.id]?.name, "Unique Goblin")
        XCTAssertEqual(try coordinator.catalog.profiles(), [.defaultProfile, profile])
        XCTAssertEqual(coordinator.windows.count, 0)
        let failed = try self.coordinator(refuseSave: true)
        defer { clean(failed) }
        do {
            _ = try await failed.create(name: "Must not publish")
            XCTFail("A refused settings save must not publish a profile")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Refused settings")
        }
        XCTAssertEqual(failed.stores.count, 1, "Prepared runtime remains owned for shutdown")
        XCTAssertEqual(try failed.catalog.profiles(), [.defaultProfile])
    }

    func testRebindingClearsOldEditorAndWaitsForAttachedSheet() async throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let controller = try coordinator.present(.defaultProfile)
        let original = controller.store
        let second = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(second)
        let window = try XCTUnwrap(controller.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet) { _ in }
        XCTAssertThrowsError(try coordinator.present(second, in: controller))
        XCTAssertTrue(controller.store === original)
        window.endSheet(sheet)
        sheet.orderOut(nil)
        await Task.yield()
        let editor = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 25))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(editor.currentEditor())
        _ = try coordinator.present(second, in: controller)
        XCTAssertNil(editor.currentEditor(), "An outgoing editor cannot receive the incoming profile's typing")
    }

    func testDockReopenPreservesCurrentNamedProfilesSettingsInsteadOfDefault() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let delegate = try GoblinAppDelegate(product: Product.load(from: root), resources: root.appendingPathComponent("Resources"), home: home)
        let coordinator = delegate.coordinator
        defer { clean(coordinator) }
        let firstStore = try coordinator.retainStore(for: .defaultProfile)
        firstStore.finishConnection(Self.snapshot(name: "Default", revision: 1), generation: firstStore.beginConnection())
        _ = try coordinator.present(.defaultProfile)
        let named = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(named)
        let namedStore = try coordinator.retainStore(for: named)
        namedStore.finishConnection(Self.snapshot(name: "Named", revision: 1), generation: namedStore.beginConnection())
        let current = try coordinator.present(named)
        namedStore.settingsVisible = true
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(namedStore.settingsVisible)
        XCTAssertTrue(coordinator.focusedWindow === current)
        XCTAssertEqual(current.profile, named)
        namedStore.defaults.removePersistentDomain(forName: namedStore.product.bundleID + ".profile." + named.id)
    }

    func testHeaderMenuRoutesRecallAndNewWindowWithoutReplacingRuntimes() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let current = try coordinator.present(.defaultProfile)
        let original = try XCTUnwrap(current.store)
        original.draft = "Kept by the outgoing Goblin"
        let generation = original.connectionGeneration
        let second = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(second)
        let delayedOldAction = original.selectProfile
        original.selectProfile?(second.id, false)
        XCTAssertEqual(current.profile, second)
        XCTAssertEqual(coordinator.windows.count, 1)
        XCTAssertEqual(original.connectionGeneration, generation)
        XCTAssertEqual(original.draft, "Kept by the outgoing Goblin")
        delayedOldAction?(GoblinProfile.defaultProfile.id, false)
        XCTAssertEqual(current.profile, second, "A delayed old menu action cannot retarget the newly presented Goblin")
        let secondStore = try XCTUnwrap(current.store)
        secondStore.selectProfile?(GoblinProfile.defaultProfile.id, true)
        XCTAssertEqual(coordinator.windows.count, 2)
        XCTAssertTrue(coordinator.focusedWindow?.store === original)
        secondStore.selectProfile?(GoblinProfile.defaultProfile.id, true)
        XCTAssertEqual(coordinator.windows.count, 2, "Opening an existing presentation focuses it")
        XCTAssertEqual(current.profile, second)
        XCTAssertEqual(coordinator.stores.count, 2)
    }

    func testHeaderMenuNamesRefreshOnCanonicalRenameNotStreamUpdates() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let controller = try coordinator.present(.defaultProfile)
        let store = try XCTUnwrap(controller.store)
        let second = try coordinator.catalog.prepare()
        try coordinator.catalog.publish(second)
        let other = try coordinator.retainStore(for: second)
        XCTAssertEqual(store.profileChoices.count, 2)
        var nameChanges = 0
        let refreshChoices = store.profileNameChanged
        store.profileNameChanged = {
            nameChanges += 1
            refreshChoices?()
        }
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("Another token")]))
        store.apply(Self.snapshot(name: store.name, revision: 2))
        XCTAssertEqual(nameChanges, 0)
        store.apply(Self.snapshot(name: "New canonical name", revision: 3))
        XCTAssertEqual(nameChanges, 1)
        XCTAssertEqual(store.profileChoices.first?.name, "New canonical name")
        XCTAssertEqual(other.profileChoices.first?.name, "New canonical name")
        XCTAssertEqual(controller.window?.title, "New canonical name")
    }

    func testHeaderCreateActionOpensExistingPickerWithoutCreatingOrSaving() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let controller = try coordinator.present(.defaultProfile)
        var pickerOwner: CompanionWindowController?
        coordinator.showProfiles = { pickerOwner = $0 }
        let before = try coordinator.catalog.profiles()
        controller.store?.showProfiles?()
        XCTAssertTrue(pickerOwner === controller)
        XCTAssertEqual(try coordinator.catalog.profiles(), before)
        XCTAssertEqual(coordinator.stores.count, 1)
        XCTAssertEqual(coordinator.windows.count, 1)
    }

    func testHeaderCatalogErrorIsReportedWithoutReplacingRuntimeErrorOrWork() throws {
        let coordinator = try coordinator()
        defer { clean(coordinator) }
        let controller = try coordinator.present(.defaultProfile)
        let store = try XCTUnwrap(controller.store)
        let generation = store.connectionGeneration
        store.error = "Existing runtime error"
        let catalogFile = coordinator.catalog.applicationHome.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: coordinator.catalog.applicationHome, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: catalogFile)
        coordinator.refreshProfileChoices()
        XCTAssertFalse(store.profileChoicesError.isEmpty)
        XCTAssertTrue(store.profileChoices.isEmpty)
        XCTAssertEqual(store.error, "Existing runtime error")
        XCTAssertEqual(store.connectionGeneration, generation)
        try Data("{\"version\":1,\"profiles\":[{\"id\":\"default\"}]}".utf8).write(to: catalogFile)
        coordinator.refreshProfileChoices()
        XCTAssertTrue(store.profileChoicesError.isEmpty)
        XCTAssertEqual(store.profileChoices.count, 1)
    }
}
