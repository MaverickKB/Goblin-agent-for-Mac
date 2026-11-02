import XCTest
@testable import Goblin

final class MemoryCoreDraftTests: XCTestCase {
    func testSelectingCreatedCoreChangesOnlyItsDraftLocation() throws {
        let original = "{\"aethermind\":{\"mode\":\"remote\",\"endpoint\":\"https://example.test/mcp\",\"project\":\"old\"},\"tools\":{\"disabled\":[\"shell\"]},\"compactor\":{\"workers\":2}}"
        let updated = try MemoryCoreDraft.selectingLocalProject("/new/core", in: original)
        let before = try SettingsAdvancedDraft.parseObject(original)
        let after = try SettingsAdvancedDraft.parseObject(updated)
        XCTAssertEqual(after["tools"], before["tools"])
        XCTAssertEqual(after["compactor"], before["compactor"])
        XCTAssertEqual(after["aethermind"]?["endpoint"], before["aethermind"]?["endpoint"])
        XCTAssertEqual(after["aethermind"]?["project"], before["aethermind"]?["project"])
        XCTAssertEqual(after["aethermind"]?["mode"], .string("embedded"))
        XCTAssertEqual(after["aethermind"]?["local_project"], .string("/new/core"))
        XCTAssertEqual(try SettingsAdvancedDraft.parseObject(original), before)
    }

    func testInvalidDraftOrMissingCreationResultLeavesOriginalAvailable() {
        XCTAssertThrowsError(try MemoryCoreDraft.selectingLocalProject("/new", in: "not JSON"))
        XCTAssertThrowsError(try MemoryCoreDraft.selectingLocalProject("/new", in: "{\"aethermind\":3}"))
        XCTAssertThrowsError(try MemoryCoreDraft.selectingLocalProject("", in: "{}"))
    }
}
