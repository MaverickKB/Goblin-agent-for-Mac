import AppKit
import XCTest
@testable import Goblin

final class SettingsUsabilityTests: XCTestCase {
    @MainActor
    func testSavedModelsRoundTripAndCompressionCopiesSupportedFields() throws {
        var draft = SettingsFormDraft()
        var first = CustomModelDraft()
        first.name = "Local model"
        first.endpoint = "http://127.0.0.1:9000/v1"
        first.model = "first"
        first.reasoning = "high"
        first.thinkingBudget = 256
        var second = CustomModelDraft()
        second.name = "LAN model"
        second.endpoint = "http://example.test:9001/v1"
        second.model = "second"
        draft.useCustomModelForChat(first)
        XCTAssertEqual(draft.endpoint, first.endpoint)
        XCTAssertEqual(draft.model, first.model)
        XCTAssertEqual(draft.reasoning, "high")
        XCTAssertEqual(draft.thinkingBudget, 256)
        draft.customModels[first.id] = first
        draft.customModels[second.id] = second
        draft.advancedText = "{\"compactor\":{\"workers\":3},\"skills\":{\"enabled\":true}}"
        draft.advancedText = try SettingsConfiguration.applyingCompression(second, to: draft.advancedText)
        let saved = try draft.saveRequest()
        let restored = SettingsFormDraft.loaded(from: .object(saved.settings), revision: 8)
        XCTAssertEqual(restored.customModels[first.id], first)
        XCTAssertEqual(restored.customModels[second.id], second)
        let values = try SettingsAdvancedDraft.parseObject(restored.advancedText)
        XCTAssertEqual(values["compactor"]?["model"].stringValue, "second")
        XCTAssertEqual(values["compactor"]?["workers"].numberValue, 3)
        XCTAssertEqual(values["skills"]?["enabled"], .bool(true))
        XCTAssertEqual(restored.model, draft.model)
    }

    @MainActor
    func testToolAndServerEditsPreserveOtherConfiguration() throws {
        let initial = "{\"tools\":{\"timeout\":45,\"disabled\":[\"shell\"]},\"compactor\":{\"workers\":3}}"
        let enabled = try SettingsConfiguration.setTool("shell", enabled: true, in: initial)
        XCTAssertTrue(SettingsConfiguration.toolEnabled("shell", in: enabled))
        let disabled = try SettingsConfiguration.setTool("write_file", enabled: false, in: enabled)
        XCTAssertFalse(SettingsConfiguration.toolEnabled("write_file", in: disabled))
        var server = MCPServerDraft()
        server.name = "existing-server"
        server.url = "https://example.test/mcp"
        let added = try SettingsConfiguration.setServer(server.name, value: server.value(), in: disabled)
        let parsed = try SettingsAdvancedDraft.parseObject(added)
        XCTAssertEqual(parsed["tools"]?["timeout"].numberValue, 45)
        XCTAssertEqual(parsed["compactor"]?["workers"].numberValue, 3)
        let removed = try SettingsConfiguration.setServer(server.name, value: nil, in: added)
        XCTAssertTrue(try SettingsAdvancedDraft.parseObject(removed)["mcp_servers"]!.objectValue.isEmpty)
        XCTAssertThrowsError(try SettingsConfiguration.setTool("shell", enabled: true, in: "{\"tools\":[]}"))
        server.usesCommand = true
        server.command = "[\"/path/to/server\", \"--stdio\"]"
        XCTAssertEqual(try server.value()["command"].arrayValue.count, 2)
    }

    @MainActor
    func testGuidedFloorEditsPreserveExistingRuleConditions() throws {
        let initial = "{\"compose\":{\"world_view\":\"Keep this\",\"quiet_paragraph\":\"Old\"},\"rules\":[{\"id\":\"disk\",\"enabled\":true,\"when\":\"disk_percent < 10\"},{\"id\":\"other\",\"enabled\":true}]}"
        let toggled = try SettingsConfiguration.setFloorRule(0, enabled: false, in: initial)
        let edited = try SettingsConfiguration.setFloorGuidance("New guidance", in: toggled)
        let result = try SettingsAdvancedDraft.parseObject(edited)
        XCTAssertEqual(result["rules"]?.arrayValue[0]["when"].stringValue, "disk_percent < 10")
        XCTAssertEqual(result["rules"]?.arrayValue[0]["enabled"], .bool(false))
        XCTAssertEqual(result["rules"]?.arrayValue[1]["enabled"], .bool(true))
        XCTAssertEqual(result["compose"]?["world_view"].stringValue, "Keep this")
        XCTAssertEqual(result["compose"]?["quiet_paragraph"].stringValue, "New guidance")
    }

    @MainActor
    func testNativeEditorDoesNotReplaceEqualBufferAndPreservesSelection() {
        let editor = NSTextView()
        editor.string = "{\n  \"name\": \"value\"\n}"
        editor.setSelectedRange(NSRange(location: 13, length: 3))
        let undo = editor.undoManager
        SettingsTextEditor.applyExternalText(editor.string, to: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 13, length: 3))
        XCTAssertTrue(editor.undoManager === undo)
        SettingsTextEditor.applyExternalText("short", to: editor)
        XCTAssertEqual(editor.string, "short")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
    }
}
