import AppKit
import MetalKit
import XCTest
@testable import Goblin

@MainActor
private final class DisplayObserver: NSObject, MTKViewDelegate {
    var draws = 0

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        draws += 1
    }
}

final class CharacterDisplayTests: XCTestCase {
    @MainActor
    func testImportedImageRedrawsThroughWindowLifecycle() async throws {
        try await checkStaticDisplay(avatarID: "imported-image", motionEnabled: true)
    }

    @MainActor
    func testAnimationDisabledCharacterRedrawsThroughWindowLifecycle() async throws {
        try await checkStaticDisplay(avatarID: "guard", motionEnabled: false)
    }

    @MainActor
    private func checkStaticDisplay(avatarID: String, motionEnabled: Bool) async throws {
        _ = NSApplication.shared
        let file = URL(fileURLWithPath: #filePath)
        let testDirectory = file.deletingLastPathComponent()
        let testsDirectory = testDirectory.deletingLastPathComponent()
        let root = testsDirectory.deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources")
        let imageURL = resources.appendingPathComponent("Standing/guard.png")
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        let view = CharacterView(frame: NSRect(x: 0, y: 0, width: 208, height: 300))
        let observer = DisplayObserver()
        view.delegate = observer
        view.motionEnabled = motionEnabled
        try view.configure(id: avatarID, resources: resources) { image }
        observer.draws = 0

        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: view.frame)
        window.contentView = host
        host.addSubview(view)
        window.orderBack(nil)
        defer {
            view.detach()
            window.orderOut(nil)
            window.close()
        }

        await waitForDisplay(observer, after: 0)
        XCTAssertGreaterThan(observer.draws, 0, "A static character needs its first frame after attachment")

        let beforeResize = observer.draws
        view.frame.size = NSSize(width: 220, height: 320)
        await waitForDisplay(observer, after: beforeResize)
        XCTAssertGreaterThan(observer.draws, beforeResize, "A static character must redraw at its new size")

        view.removeFromSuperview()
        observer.draws = 0
        host.addSubview(view)
        await waitForDisplay(observer, after: 0)
        XCTAssertGreaterThan(observer.draws, 0, "Reattachment must restore the static character")

        try await Task.sleep(for: .milliseconds(100))
        let settledDraws = observer.draws
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(observer.draws, settledDraws, "A static character must not depend on a running draw loop")
    }

    @MainActor
    private func waitForDisplay(_ observer: DisplayObserver, after count: Int) async {
        for _ in 0..<100 {
            if observer.draws > count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
