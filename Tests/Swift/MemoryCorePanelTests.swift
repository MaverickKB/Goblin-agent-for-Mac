import AppKit
import XCTest
@testable import Goblin

final class MemoryCorePanelTests: XCTestCase {
    @MainActor
    func testPickerBelongsToCompanionAndCancellationHasNoSelection() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSOpenPanel()
        let finished = expectation(description: "Picker cancelled")
        var selected: URL?
        MemoryCoreFilePanel.present(panel, for: window) { url in
            selected = url
            finished.fulfill()
        }
        XCTAssertTrue(window.attachedSheet === panel)
        window.endSheet(panel, returnCode: .cancel)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(selected)
    }
}
