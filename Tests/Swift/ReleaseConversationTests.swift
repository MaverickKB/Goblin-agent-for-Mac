import Foundation
import XCTest
@testable import Goblin

final class ReleaseConversationTests: XCTestCase {
    @MainActor
    private func store() throws -> GoblinStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try GoblinStore(product: Product.load(from: root), resources: root.appendingPathComponent("Resources"), home: home)
        let connection = store.beginConnection()
        store.finishConnection(.object([:]), generation: connection)
        return store
    }

    @MainActor
    func testSetupKeepsTheDraftAndDoesNotCreateADoomedTurn() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.home) }
        store.draft = "Hello"
        XCTAssertFalse(store.canSend)
        store.apply(.object(["revision": .number(1), "ready": .bool(false),
            "setup_issue": .string("Configure a chat model in Settings."),
            "settings": .object(["agent_name": .string("Goblin")])]))
        XCTAssertTrue(store.settingsLoaded)
        await store.send()
        XCTAssertEqual(store.draft, "Hello")
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertTrue(store.error.contains("Configure"))
        store.apply(.object(["revision": .number(2), "ready": .bool(true),
            "settings": .object(["agent_name": .string("Goblin")])]))
        XCTAssertTrue(store.canSend)
    }

    @MainActor
    func testQueuedMessageDoesNotCaptureTheActiveStream() throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.home) }
        let initial: JSONValue = .object(["revision": .number(1), "ready": .bool(true), "busy": .bool(true),
            "active_turn_id": .string("active"), "messages": .array([
                .object(["id": .string("1"), "kind": .string("user"), "text": .string("First"), "turn_id": .string("active")]),
                .object(["id": .string("2"), "kind": .string("user"), "text": .string("Later"), "turn_id": .string("queued")])])])
        store.mergeHistoryPage(initial)
        store.apply(initial)
        store.receive("activity", .object(["phase": .string("model_start"), "turn_id": .string("active"),
            "response_id": .string("response"), "revision": .number(2)]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("Answer to first"), "revision": .number(2)]))
        XCTAssertEqual(store.liveTurnID, "active")
        XCTAssertEqual(store.turns.last?.id, "queued")
        XCTAssertNotEqual(store.liveTurnID, store.turns.last?.id)
        let settled: JSONValue = .object(["revision": .number(3), "ready": .bool(true), "busy": .bool(false),
            "active_turn_id": .string(""), "messages": .array([
                .object(["id": .string("1"), "kind": .string("user"), "text": .string("First"), "turn_id": .string("active")]),
                .object(["id": .string("2"), "kind": .string("user"), "text": .string("Later"),
                    "turn_id": .string("queued"), "status": .string("cancelled")])])])
        store.mergeHistoryPage(settled)
        store.apply(settled)
        XCTAssertEqual(store.messages.last?.status, "cancelled")
        XCTAssertEqual(store.messages.last?.text, "Later")
        XCTAssertEqual(store.liveTurnID, "")
    }
}
