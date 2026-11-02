import Foundation
import XCTest
@testable import Goblin

final class IntakeRecoveryTests: XCTestCase {
    @MainActor
    func testTerminalErrorReplacesPendingWithOneFailedRowAndRestoresAttachments() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let file = try ReleaseRepairTestSupport.attachment()
        defer { ReleaseRepairTestSupport.removeAttachment(file) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        let initial = ReleaseRepairTestSupport.snapshot(revision: 2)
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/send" {
                return .object(["turn_id": params["request_id"] ?? .string("")])
            }
            return initial
        }
        store.draft = "Keep this text"
        store.attachedFiles = [file]
        await store.send()
        let requestID = probe.lastParameters(for: "chat/send")?["request_id"]?.stringValue ?? ""
        XCTAssertFalse(requestID.isEmpty)
        XCTAssertEqual(store.pendingMessages.count, 1)
        let terminal = ReleaseRepairTestSupport.snapshot(revision: 3, turns: [
            .object(["id": .string(requestID), "state": .string("error"),
                     "text": .string("Keep this text"), "error": .string("Model failed")])
        ])
        store.apply(terminal)
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertEqual(store.localIntakeRows.count, 1)
        XCTAssertEqual(store.localIntakeRows[0].status, "failed")
        XCTAssertEqual(store.localIntakeRows[0].text, "Keep this text")
        XCTAssertEqual(store.attachedFiles, [file])
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].prompt?.text, "Keep this text")
        let durable = ReleaseRepairTestSupport.snapshot(revision: 4, turns: [
            .object(["id": .string(requestID), "state": .string("cancelled")])
        ], messages: [
            .object(["id": .string("77"), "kind": .string("user"), "text": .string("Keep this text"),
                     "turn_id": .string(requestID), "status": .string("cancelled")])
        ])
        store.mergeHistoryPage(durable)
        store.apply(durable)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].prompt?.id, "77")
    }

    @MainActor
    func testSteerAcceptedWhileBusyClearsTheDraft() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1, busy: true, activeTurnID: "turn-a"))
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/steer" { return .object(["accepted": .bool(true)]) }
            return ReleaseRepairTestSupport.snapshot(revision: 2, busy: true, activeTurnID: "turn-a")
        }
        store.draft = "Go left"
        await store.steer()
        XCTAssertEqual(probe.methods, ["chat/steer"])
        XCTAssertEqual(probe.lastParameters(for: "chat/steer")?["text"]?.stringValue, "Go left")
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.livePhase, "Direction received")
    }

    @MainActor
    func testSteerFallsBackToSendWhenNoTurnIsOpen() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1, busy: false))
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/steer" { return .object(["accepted": .bool(false)]) }
            if method == "chat/send" {
                return .object(["turn_id": params["request_id"] ?? .string("")])
            }
            return ReleaseRepairTestSupport.snapshot(revision: 2, busy: true)
        }
        store.draft = "New task"
        await store.steer()
        XCTAssertEqual(Array(probe.methods.prefix(2)), ["chat/steer", "chat/send"])
        XCTAssertEqual(probe.lastParameters(for: "chat/send")?["text"]?.stringValue, "New task")
    }

    @MainActor
    func testCancelledRawRowReplacesPendingWithoutDuplicate() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        let initial = ReleaseRepairTestSupport.snapshot(revision: 2)
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/send" {
                return .object(["turn_id": params["request_id"] ?? .string("")])
            }
            return initial
        }
        store.draft = "Stopped text"
        await store.send()
        let requestID = probe.lastParameters(for: "chat/send")?["request_id"]?.stringValue ?? ""
        XCTAssertEqual(store.pendingMessages.count, 1)
        let cancelled = ReleaseRepairTestSupport.snapshot(revision: 3, turns: [
            .object(["id": .string(requestID), "state": .string("cancelled")])
        ], messages: [
            .object(["id": .string("91"), "kind": .string("user"), "text": .string("Stopped text"),
                     "turn_id": .string(requestID), "status": .string("cancelled")])
        ])
        store.mergeHistoryPage(cancelled)
        store.apply(cancelled)
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].prompt?.id, "91")
        XCTAssertEqual(store.turns[0].prompt?.text, "Stopped text")
        XCTAssertTrue(store.attachedFiles.isEmpty)
    }

    @MainActor
    func testRunningTurnKeepsThePendingBubbleUntilATerminalState() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        let initial = ReleaseRepairTestSupport.snapshot(revision: 2)
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/send" {
                return .object(["turn_id": params["request_id"] ?? .string("")])
            }
            return initial
        }
        store.draft = "Working text"
        await store.send()
        let requestID = probe.lastParameters(for: "chat/send")?["request_id"]?.stringValue ?? ""
        let running = ReleaseRepairTestSupport.snapshot(revision: 3, busy: true, activeTurnID: requestID,
            turns: [.object(["id": .string(requestID), "state": .string("running"),
                             "text": .string("Working text")])])
        store.apply(running)
        XCTAssertEqual(store.pendingMessages.count, 1)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertEqual(store.liveTurnID, requestID)
    }

    @MainActor
    func testIntakeErrorPreservesNewerDraftAndAllAttachments() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let oldFile = try ReleaseRepairTestSupport.attachment()
        let newFile = try ReleaseRepairTestSupport.attachment()
        defer {
            ReleaseRepairTestSupport.removeAttachment(oldFile)
            ReleaseRepairTestSupport.removeAttachment(newFile)
        }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        let gate = AsyncGate()
        let probe = RPCProbe()
        let initial = ReleaseRepairTestSupport.snapshot(revision: 2)
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/send" {
                await gate.wait()
                throw GoblinError(message: "Turn was fenced by operator Stop")
            }
            return initial
        }
        store.draft = "Old text"
        store.attachedFiles = [oldFile]
        let task = Task { await store.send() }
        await waitForRPCMethod(probe, "chat/send")
        store.draft = "Newer text"
        store.attachedFiles = [newFile]
        await gate.release()
        await task.value
        XCTAssertEqual(store.draft, "Newer text")
        let paths = Set(store.attachedFiles.map(\.path))
        XCTAssertEqual(paths, Set([oldFile.path, newFile.path]))
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertEqual(store.localIntakeRows.count, 1)
        XCTAssertEqual(store.localIntakeRows[0].text, "Old text")
        XCTAssertEqual(store.localIntakeRows[0].status, "failed")
        XCTAssertEqual(store.error, "Turn was fenced by operator Stop")
    }

    @MainActor
    func testLateRawRowWinsOverTheIntakeErrorRecovery() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/send" {
                let requestID = params["request_id"]?.stringValue ?? ""
                let durable = ReleaseRepairTestSupport.snapshot(revision: 2, turns: [
                    .object(["id": .string(requestID), "state": .string("cancelled")])
                ], messages: [
                    .object(["id": .string("5"), "kind": .string("user"), "text": .string("Raced text"),
                             "turn_id": .string(requestID), "status": .string("cancelled")])
                ])
                store.mergeHistoryPage(durable)
        store.apply(durable)
                throw GoblinError(message: "Turn was fenced by operator Stop")
            }
            return ReleaseRepairTestSupport.snapshot(revision: 3)
        }
        store.draft = "Raced text"
        await store.send()
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].prompt?.text, "Raced text")
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.error, "Turn was fenced by operator Stop")
    }

    @MainActor
    func testIntakeErrorRestoresTheComposerWhenNothingNewerExists() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let file = try ReleaseRepairTestSupport.attachment()
        defer { ReleaseRepairTestSupport.removeAttachment(file) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        store.rpc = { _, _ in
            throw GoblinError(message: "Engine unavailable")
        }
        store.draft = "Old text"
        store.attachedFiles = [file]
        await store.send()
        XCTAssertEqual(store.draft, "Old text")
        XCTAssertEqual(store.attachedFiles, [file])
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertEqual(store.error, "Engine unavailable")
    }

    @MainActor
    func testAcceptedSteerKeepsANewerDraft() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let busy = ReleaseRepairTestSupport.snapshot(revision: 1, busy: true, activeTurnID: "turn-1")
        store.apply(busy)
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/steer" {
                await gate.wait()
                return .object(["accepted": .bool(true)])
            }
            return busy
        }
        store.draft = "Direction A"
        let task = Task { await store.steer() }
        await waitForRPCMethod(probe, "chat/steer")
        store.draft = "Draft B"
        await gate.release()
        await task.value
        XCTAssertEqual(store.draft, "Draft B")
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertFalse(probe.methods.contains("chat/send"))
    }

    @MainActor
    func testDeclinedSteerDoesNotSendAfterStop() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let busy = ReleaseRepairTestSupport.snapshot(revision: 1, busy: true, activeTurnID: "turn-1")
        store.apply(busy)
        let idle = ReleaseRepairTestSupport.snapshot(revision: 2)
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "chat/steer" {
                await gate.wait()
                return .object(["accepted": .bool(false)])
            }
            if method == "chat/stop" {
                return .object(["stopped": .bool(true)])
            }
            return idle
        }
        store.draft = "Direction A"
        let task = Task { await store.steer() }
        await waitForRPCMethod(probe, "chat/steer")
        await store.stop()
        await gate.release()
        await task.value
        XCTAssertEqual(store.draft, "Direction A")
        XCTAssertTrue(store.pendingMessages.isEmpty)
        XCTAssertTrue(store.localIntakeRows.isEmpty)
        XCTAssertFalse(probe.methods.contains("chat/send"))
    }
}
