import AppKit
import Foundation
import XCTest
@testable import Goblin

final class ProfileStoreTests: XCTestCase {
    @MainActor
    func testSavedGoblinNameUpdatesItsPresentedWindowTitle() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = "Previous name"
        store.presentationWindow = window
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1, agentName: "Renamed Goblin"))
        XCTAssertEqual(window.title, "Renamed Goblin")
        XCTAssertEqual(store.name, "Renamed Goblin")
    }

    @MainActor
    func testDistinctProfilesKeepPreferencesAvatarsAndEventsIndependent() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstSuite = "profile-first-" + UUID().uuidString
        let secondSuite = "profile-second-" + UUID().uuidString
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
            try? FileManager.default.removeItem(at: root)
        }
        let product = try Product.load(from: source)
        let resources = source.appendingPathComponent("Resources")
        let firstHome = root.appendingPathComponent("profiles/first")
        let secondHome = root.appendingPathComponent("profiles/second")
        let first = try GoblinStore(product: product, resources: resources, home: firstHome,
                                    applicationHome: root, profileID: "first", defaults: firstDefaults)
        let second = try GoblinStore(product: product, resources: resources, home: secondHome,
                                     applicationHome: root, profileID: "second", defaults: secondDefaults)
        XCTAssertEqual(first.applicationHome, second.applicationHome)
        XCTAssertNotEqual(first.home, second.home)
        XCTAssertFalse(first.engine === second.engine)
        first.preferences.alwaysOnTop = true
        first.preferences.animations = false
        first.chooseAvatar(try XCTUnwrap(first.avatars.last).id)
        firstDefaults.set(true, forKey: "allowSpeakers")
        firstDefaults.set("Continuity", forKey: "settingsSection")
        XCTAssertFalse(second.preferences.alwaysOnTop)
        XCTAssertTrue(second.preferences.animations)
        XCTAssertNil(secondDefaults.string(forKey: "avatar"))
        XCTAssertFalse(secondDefaults.bool(forKey: "allowSpeakers"))
        XCTAssertNil(secondDefaults.string(forKey: "settingsSection"))
        let reopened = try GoblinStore(product: product, resources: resources, home: firstHome,
                                       applicationHome: root, profileID: "first", defaults: firstDefaults)
        XCTAssertEqual(reopened.selectedAvatar, first.selectedAvatar)
        XCTAssertTrue(reopened.voice.allowSpeakers)
        XCTAssertTrue(reopened.preferences.alwaysOnTop)
        let token = first.beginConnection()
        first.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: token)
        first.receive("message", .object(["id": .string("first-record"), "kind": .string("user"), "text": .string("First profile only")]))
        XCTAssertTrue(first.messages.contains { $0.text == "First profile only" })
        XCTAssertTrue(second.messages.isEmpty)
        XCTAssertEqual(first.product.keychainServices, second.product.keychainServices)
    }

    @MainActor
    func testLegacyConstructorKeepsExistingDefaultLocationsAndDefaults() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        XCTAssertEqual(store.applicationHome, store.home)
        XCTAssertEqual(store.profileID, "default")
        XCTAssertTrue(store.defaults === UserDefaults.standard)
    }
}
