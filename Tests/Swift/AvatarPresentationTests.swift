import AppKit
import XCTest
@testable import Goblin

final class AvatarPresentationTests: XCTestCase {
    private func avatarRecords(_ avatars: [Avatar]) -> [[String]] {
        var records: [[String]] = []
        for avatar in avatars {
            records.append([avatar.id, avatar.name, avatar.file, avatar.standingFile])
        }
        return records
    }

    @MainActor
    func testImportRequiresItsOwningWindow() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let before = avatarRecords(store.avatars)
        store.importAvatar()
        XCTAssertFalse(store.error.isEmpty)
        let after = avatarRecords(store.avatars)
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testImportUsesAnOwnedSheetAndCancellationKeepsTheLibrary() async throws {
        _ = NSApplication.shared
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                             styleMask: .borderless, backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        store.presentationWindow = owner
        let before = avatarRecords(store.avatars)
        let selected = store.selectedAvatar
        store.importAvatar()
        let panel = try XCTUnwrap(owner.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.sheetParent === owner)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        owner.endSheet(panel, returnCode: .cancel)
        await Task.yield()
        let after = avatarRecords(store.avatars)
        XCTAssertEqual(after, before)
        XCTAssertEqual(store.selectedAvatar, selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.home.appendingPathComponent("avatars/catalog.json").path))
    }
}
