import XCTest
@testable import Goblin

final class ToolExposureTests: XCTestCase {
    func testPauseDraftUsesRegistryMetadataAndPreservesAuthorityAndOtherSettings() throws {
        let tools: [JSONValue] = [
            .object(["name": .string("custom_action"), "risky": .bool(true)]),
            .object(["name": .string("background_task"), "risky": .bool(false),
                     "approval_classes": .array([.string("acting")])]),
            .object(["name": .string("web_fetch"), "risky": .bool(false)]),
            .object(["name": .string("memory_note"), "risky": .bool(false),
                     "approval_classes": .array([.string("memory-self")])]),
            .object(["name": .string("read_file"), "risky": .bool(false),
                     "description": .string("Can read shell secrets and network files")])
        ]
        let initial = """
        {"tools":{"disabled":["unloaded_tool","custom_action"],"timeout":45,
        "approval_rules":{"acting":"allow"},"approval_classes":{"acting":["background_*"]}},
        "compactor":{"workers":3},"approval":"unleashed"}
        """
        let names = SettingsConfiguration.actingToolNames(tools)
        XCTAssertEqual(names, ["custom_action", "background_task"])
        let paused = try SettingsConfiguration.setTools(names, enabled: false, in: initial)
        let result = try SettingsAdvancedDraft.parseObject(paused)
        XCTAssertEqual(result["tools"]?["disabled"].arrayValue,
                       [.string("unloaded_tool"), .string("custom_action"), .string("background_task")])
        let original = try SettingsAdvancedDraft.parseObject(initial)
        XCTAssertEqual(result["approval"], original["approval"])
        XCTAssertEqual(result["tools"]?["approval_rules"], original["tools"]?["approval_rules"])
        XCTAssertEqual(result["tools"]?["approval_classes"], original["tools"]?["approval_classes"])
        XCTAssertEqual(result["tools"]?["timeout"], original["tools"]?["timeout"])
        XCTAssertEqual(result["compactor"], original["compactor"])
        XCTAssertTrue(SettingsConfiguration.toolEnabled("web_fetch", in: paused))
        XCTAssertTrue(SettingsConfiguration.toolEnabled("read_file", in: paused))
        XCTAssertTrue(SettingsConfiguration.toolEnabled("memory_note", in: paused))
        XCTAssertEqual(try SettingsConfiguration.setTools(names, enabled: false, in: paused), paused)
    }

    func testRegisteredToolsCanBeReenabledWithoutChangingAbsentToolChoices() throws {
        let initial = "{\"tools\":{\"disabled\":[\"shell\",\"write_file\",\"unloaded\"]}}"
        let single = try SettingsConfiguration.setTool("shell", enabled: true, in: initial)
        XCTAssertTrue(SettingsConfiguration.toolEnabled("shell", in: single))
        XCTAssertFalse(SettingsConfiguration.toolEnabled("write_file", in: single))
        let all = try SettingsConfiguration.setTools(["shell", "write_file"], enabled: true, in: single)
        XCTAssertEqual(try SettingsAdvancedDraft.parseObject(all)["tools"]?["disabled"].arrayValue,
                       [.string("unloaded")])
        XCTAssertThrowsError(try SettingsConfiguration.setTools(["shell"], enabled: false,
                                                              in: "{\"tools\":{\"disabled\":false}}"))
    }

    func testAuthorityLabelsDescribeRuntimeMetadataSeparatelyFromDraft() throws {
        let tool = JSONValue.object(["name": .string("shell"), "enabled": .bool(true),
                                     "risky": .bool(true), "approval_rule": .string("allow"),
                                     "approval_classes": .array([.string("acting")]), "origin": .string("built-in")])
        let draft = try SettingsConfiguration.setTool("shell", enabled: false, in: "{}")
        XCTAssertFalse(SettingsConfiguration.toolEnabled("shell", in: draft))
        XCTAssertEqual(SettingsConfiguration.toolAuthority(tool),
                       "Runtime enabled · marked risky · approval rule: allow · class: acting · origin: built-in")
        XCTAssertEqual(SettingsConfiguration.toolAuthority(.object(["enabled": .bool(false)])), "Runtime disabled")
    }
}
