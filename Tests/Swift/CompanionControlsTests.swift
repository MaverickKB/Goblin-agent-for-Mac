import AppKit
import SwiftUI
import XCTest
@testable import Goblin

@MainActor
private final class TestCompanionVoice: CompanionVoice {
    var isConnected = false
    var muted = false
    var suspendStart = false
    var requestedMute: Bool?
    var started: (() -> Void)?
    var pending: CheckedContinuation<Void, Never>?

    func start(initiallyMuted: Bool) async throws {
        requestedMute = initiallyMuted
        muted = initiallyMuted
        started?()
        if suspendStart {
            await withCheckedContinuation { pending = $0 }
        }
        isConnected = true
    }

    func setMuted(_ muted: Bool) { self.muted = muted }
}

final class CompanionControlsTests: XCTestCase {
    @MainActor
    func testPreferencesPersistAndNotifyWindowOwner() throws {
        let suite = "companion-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CompanionPreferences(defaults: defaults)
        XCTAssertFalse(preferences.alwaysOnTop)
        XCTAssertTrue(preferences.animations)
        var notifications = 0
        preferences.windowLevelChanged = { notifications += 1 }
        preferences.alwaysOnTop = true
        preferences.animations = false
        preferences.pushToTalk = true
        let reopened = CompanionPreferences(defaults: defaults)
        XCTAssertTrue(reopened.alwaysOnTop)
        XCTAssertFalse(reopened.animations)
        XCTAssertTrue(reopened.pushToTalk)
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testPushToTalkReleaseKeepsConnectedPlaybackSession() {
        let voice = TestCompanionVoice()
        voice.isConnected = true
        voice.muted = true
        let controller = PushToTalkController(voice: voice)
        controller.press()
        XCTAssertFalse(voice.muted)
        controller.release()
        XCTAssertTrue(voice.muted)
        XCTAssertTrue(voice.isConnected)
        XCTAssertFalse(controller.isHeld)
    }

    @MainActor
    func testReleaseDuringConnectionNeverUnmutesLateStart() async throws {
        let voice = TestCompanionVoice()
        voice.suspendStart = true
        let controller = PushToTalkController(voice: voice)
        var connection: Task<Void, Never>?
        await withCheckedContinuation { began in
            voice.started = { began.resume() }
            connection = controller.press()
        }
        XCTAssertEqual(voice.requestedMute, true)
        controller.release()
        voice.pending?.resume()
        voice.pending = nil
        await connection?.value
        XCTAssertTrue(voice.isConnected)
        XCTAssertTrue(voice.muted)
    }

    @MainActor
    func testHeldConnectionOpensMicOnlyAfterReady() async throws {
        let voice = TestCompanionVoice()
        let controller = PushToTalkController(voice: voice)
        let connection = controller.press()
        await connection?.value
        XCTAssertEqual(voice.requestedMute, true)
        XCTAssertTrue(voice.isConnected)
        XCTAssertFalse(voice.muted)
        controller.release()
        XCTAssertTrue(voice.muted)
    }

    @MainActor
    func testAccessibilityEditUpdatesTheComposerBinding() {
        var draft = ""
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let composer = NativeComposer(text: binding, label: "Message") {}
        let coordinator = composer.makeCoordinator()
        let editor = ComposerTextView()
        editor.delegate = coordinator
        editor.setAccessibilityValue("A real accessibility edit")
        XCTAssertEqual(draft, "A real accessibility edit")
    }

    @MainActor
    func testQuickComposerReturnSubmits() throws {
        let editor = ComposerTextView()
        var submissions = 0
        editor.submit = { submissions += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        XCTAssertEqual(submissions, 1)
    }

    @MainActor
    func testDraggingMovesTheWindowWithoutClickingOrTalking() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = AvatarControl(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        window.contentView = control
        defer { control.detach(); window.close() }
        var clicks = 0
        var presses = 0
        control.clicked = { clicks += 1 }
        control.holdBegan = { presses += 1 }
        control.pushToTalk = true
        let origin = window.frame.origin
        let down = try mouse(.leftMouseDown, in: window, point: NSPoint(x: 60, y: 80))
        let drag = try mouse(.leftMouseDragged, in: window, point: NSPoint(x: 100, y: 110))
        control.mouseDown(with: down)
        control.mouseDragged(with: drag)
        control.mouseUp(with: try mouse(.leftMouseUp, in: window, point: NSPoint(x: 60, y: 80)))
        XCTAssertEqual(window.frame.origin.x, origin.x + 40)
        XCTAssertEqual(window.frame.origin.y, origin.y + 30)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(presses, 0)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, in window: NSWindow, point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
