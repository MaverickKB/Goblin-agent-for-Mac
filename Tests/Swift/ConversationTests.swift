import Foundation
import XCTest
@testable import Goblin

final class ConversationTests: XCTestCase {
    private func message(_ id: String, _ kind: String, _ text: String, turn: String = "a", final: Bool = false,
                         automatic: Bool = false, response: String = "", call: String = "") -> ChatMessage {
        ChatMessage(.object(["id": .string(id), "kind": .string(kind), "text": .string(text),
                            "turn_id": .string(turn), "final": .bool(final), "automatic": .bool(automatic),
                            "response_id": .string(response), "call_id": .string(call)]))
    }

    func testInterimAndFinalRepliesRemainSeparateConversationMessages() {
        let entries = [message("1", "user", "Check it"),
                       message("2", "agent", "I will check.\nFull interim detail."),
                       message("3", "tool", "Actual command", call: "c"),
                       message("4", "result", "Actual result", call: "c"),
                       message("5", "agent", "It is ready.\nFull final detail.", final: true)]
        let turns = ConversationTurn.group(entries)
        let segments = turns[0].segments()
        XCTAssertEqual(segments.count, 4)
        guard case .message(let interim) = segments[1], case .work(let work) = segments[2],
              case .message(let final) = segments[3] else { return XCTFail("Wrong conversation order") }
        XCTAssertEqual(interim.text, entries[1].text)
        XCTAssertEqual(final.text, entries[4].text)
        XCTAssertEqual(work.calls.count, 1)
        XCTAssertEqual(work.calls[0].request?.id, "3")
        XCTAssertEqual(work.calls[0].result?.id, "4")
        XCTAssertEqual(turns[0].entries.count, entries.count)
    }

    func testConsecutiveCallsShareOneWorkSequenceAcrossEmptyModelMessages() {
        let entries = [message("1", "user", "Check three things"),
                       message("2", "tool", "First", call: "first"),
                       message("3", "result", "One", call: "first"),
                       message("4", "agent", "\n\n"),
                       message("5", "tool", "Second", call: "second"),
                       message("6", "result", "Two", call: "second"),
                       message("7", "thought", "Recorded reasoning"),
                       message("8", "tool", "Third", call: "third"),
                       message("9", "result", "Three", call: "third")]
        let turn = ConversationTurn.group(entries)[0]
        let segments = turn.segments(active: true)
        XCTAssertEqual(segments.count, 2)
        guard case .work(let work) = segments[1] else { return XCTFail("Calls were not grouped") }
        XCTAssertEqual(work.calls.count, 3)
        XCTAssertEqual(work.entries.count, entries.count - 1)
        let waiting = ConversationTurn.group([entries[0]])[0].segments(active: true)
        XCTAssertEqual(waiting.last?.id, work.id)
    }

    func testAnActualReplySeparatesWorkSequences() {
        let turn = ConversationTurn.group([message("1", "user", "Check"),
            message("2", "tool", "First"), message("3", "result", "One"),
            message("4", "agent", "The first part works. Checking the next part."),
            message("5", "tool", "Second"), message("6", "result", "Two"),
            message("7", "agent", "Done", final: true)])[0]
        let segments = turn.segments()
        XCTAssertEqual(segments.count, 5)
        guard case .work = segments[1], case .message = segments[2], case .work = segments[3]
        else { return XCTFail("Reply/work chronology was lost") }
        XCTAssertNotEqual(segments[1].id, segments[3].id)
    }

    func testStreamingAndCommittedReplyUseTheSamePresentationIdentity() {
        let user = message("1", "user", "Check")
        let stream = message("stream", "agent", "I am checking", response: "response-a")
        let committed = message("2", "agent", "I am checking it now.", response: "response-a")
        let before = ConversationTurn.group([user])[0].segments(stream: stream, active: true)
        let after = ConversationTurn.group([user, committed])[0].segments(active: true)
        XCTAssertEqual(before[1].id, after[1].id)
        XCTAssertEqual(committed.displayID, "reply-response-a")
    }

    func testDiffReceiptsRemainAttachedToTheirWork() {
        let result = ChatMessage(.object(["id": .string("2"), "kind": .string("result"),
            "turn_id": .string("a"), "text": .string("Edited"), "diffs": .array([
                .object(["path": .string("sample.txt"), "patch": .string("--- before\n+++ after\n-old\n+new\n"),
                         "change": .string("modified")])])]))
        let segments = ConversationTurn.group([message("1", "user", "Edit"), result])[0].segments()
        guard case .work(let work) = segments[1] else { return XCTFail("Missing work") }
        XCTAssertEqual(work.diffs.count, 1)
        XCTAssertEqual(work.diffs[0].path, "sample.txt")
        XCTAssertTrue(work.diffs[0].patch.contains("+new"))
    }

    func testAutomaticInstructionsStayInExplorableWork() {
        let turn = ConversationTurn.group([message("1", "user", "Internal wake", automatic: true),
                                           message("2", "agent", "Still watching.", final: true)])[0]
        XCTAssertNil(turn.prompt)
        XCTAssertEqual(turn.entries[0].text, "Internal wake")
        guard case .work(let context) = turn.segments()[0] else { return XCTFail("Wake context missing") }
        XCTAssertEqual(context.entries[0].text, "Internal wake")
    }

    func testGrowingRepliesKeepFollowingUntilTheUserScrollsOrExplores() {
        var scrolling = ConversationScrollState()
        XCTAssertTrue(scrolling.geometryChanged(atBottom: false))
        XCTAssertTrue(scrolling.followsLatest)
        _ = scrolling.geometryChanged(atBottom: true)
        scrolling.phaseChanged(userDriven: true)
        XCTAssertFalse(scrolling.geometryChanged(atBottom: false))
        scrolling.phaseChanged(userDriven: false)
        XCTAssertFalse(scrolling.followsLatest)
        scrolling.submitted()
        XCTAssertTrue(scrolling.followsLatest)
        scrolling.explore()
        XCTAssertFalse(scrolling.geometryChanged(atBottom: false))
        scrolling.submitted()
        XCTAssertTrue(scrolling.geometryChanged(atBottom: false))
    }

    @MainActor
    func testCommittedStreamIsRetainedAsAReplyWithoutDuplicatingTheLiveBuffer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try GoblinStore(product: Product.load(from: root), resources: root.appendingPathComponent("Resources"), home: home)
        let connection = store.beginConnection()
        store.finishConnection(.object([:]), generation: connection)
        store.receive("activity", .object(["phase": .string("model_start"), "response_id": .string("r1"), "revision": .number(1)]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("I will check."), "revision": .number(1)]))
        XCTAssertEqual(store.stream, "I will check.")
        store.receive("message", .object(["id": .string("1"), "turn_id": .string("t"), "kind": .string("agent"),
            "text": .string("I will check."), "response_id": .string("r1"), "final": .bool(false), "revision": .number(2)]))
        XCTAssertEqual(store.stream, "")
        store.receive("activity", .object(["phase": .string("model_start"), "response_id": .string("r2"), "revision": .number(3)]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("Done."), "revision": .number(3)]))
        store.receive("message", .object(["id": .string("2"), "turn_id": .string("t"), "kind": .string("agent"),
            "text": .string("Done."), "response_id": .string("r2"), "final": .bool(true), "revision": .number(4)]))
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[0].text, "I will check.")
        XCTAssertEqual(store.messages[1].text, "Done.")
        XCTAssertEqual(store.stream, "")
        XCTAssertEqual(store.turns[0].segments().count, 2)
    }

    @MainActor
    func testCompactionCountersFollowLiveProgressAndRejectOldSnapshots() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try GoblinStore(product: Product.load(from: root), resources: root.appendingPathComponent("Resources"), home: home)
        let connection = store.beginConnection()
        store.finishConnection(.object([:]), generation: connection)
        let initial: JSONValue = .object(["pending": .number(3), "bytes": .number(5000), "ready": .bool(false)])
        store.apply(.object(["revision": .number(1), "compaction": initial]))
        let progress: JSONValue = .object(["pending": .number(2), "bytes": .number(4000), "ready": .bool(false)])
        store.receive("activity", .object(["revision": .number(2), "phase": .string("compacting"), "compaction": progress]))
        XCTAssertEqual(store.compactionStatus, progress)
        XCTAssertTrue(store.busy)
        store.apply(.object(["revision": .number(1), "compaction": initial]))
        XCTAssertEqual(store.compactionStatus, progress)
        let ready: JSONValue = .object(["pending": .number(0), "bytes": .number(1000), "ready": .bool(true)])
        store.apply(.object(["revision": .number(3), "compaction": ready]))
        XCTAssertEqual(store.compactionStatus, ready)
    }

    @MainActor
    func testActivityEngagesBeforeASnapshotAndOldSnapshotsCannotClearIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try GoblinStore(product: Product.load(from: root), resources: root.appendingPathComponent("Resources"), home: home)
        let connection = store.beginConnection()
        store.finishConnection(.object([:]), generation: connection)
        store.receive("activity", .object(["phase": .string("queued"), "revision": .number(2)]))
        XCTAssertTrue(store.busy)
        XCTAssertTrue(store.characterSignals.thinking)
        store.apply(.object(["revision": .number(1), "busy": .bool(false)]))
        XCTAssertTrue(store.busy)
        store.receive("activity", .object(["phase": .string("tool"), "revision": .number(3)]))
        XCTAssertTrue(store.characterSignals.working)
        store.receive("activity", .object(["phase": .string("turn_end"), "revision": .number(4)]))
        store.apply(.object(["revision": .number(4), "busy": .bool(false)]))
        XCTAssertFalse(store.busy)
    }

    @MainActor
    func testANewTurnRestartsTheLiveTimer() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        store.receive("activity", .object(["revision": .number(2), "phase": .string("queued"), "turn_id": .string("turn-a")]))
        guard let firstStart = store.activityStarted else { return XCTFail("No timer for the first turn") }
        Thread.sleep(forTimeInterval: 0.02)
        store.receive("activity", .object(["revision": .number(3), "phase": .string("turn_end"), "turn_id": .string("turn-a")]))
        store.receive("activity", .object(["revision": .number(4), "phase": .string("queued"), "turn_id": .string("turn-b")]))
        guard let secondStart = store.activityStarted else { return XCTFail("No timer for the second turn") }
        XCTAssertGreaterThan(secondStart, firstStart)
    }

    @MainActor
    func testLiveThoughtArchivesIntoTheTurnWhenTheReplyArrives() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1, busy: true, activeTurnID: "turn-a"))
        store.receive("activity", .object(["revision": .number(2), "phase": .string("turn_start"), "turn_id": .string("turn-a")]))
        store.receive("activity", .object(["revision": .number(3), "phase": .string("model_start"),
                                          "turn_id": .string("turn-a"), "response_id": .string("resp-1")]))
        store.receive("stream", .object(["revision": .number(4), "kind": .string("thought"),
                                         "text": .string("Check the logs first. ")]))
        store.receive("stream", .object(["revision": .number(4), "kind": .string("thought"),
                                         "text": .string("Then write the fix.")]))
        XCTAssertEqual(store.thoughtStream, "Check the logs first. Then write the fix.")
        store.receive("message", .object(["revision": .number(5), "id": .string("m1"), "kind": .string("agent"),
                                          "text": .string("Done."), "turn_id": .string("turn-a"),
                                          "response_id": .string("resp-1"), "final": .bool(true)]))
        XCTAssertEqual(store.thoughtStream, "")
        XCTAssertEqual(store.finishedThought, "Check the logs first. Then write the fix.")
        XCTAssertEqual(store.finishedThoughtTurnID, "turn-a")
    }

    @MainActor
    func testHeartbeatRefreshesTheLiveUpdateAge() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1, busy: true))
        store.receive("activity", .object(["revision": .number(2), "phase": .string("model_start"),
                                          "turn_id": .string("turn-a"), "response_id": .string("r1")]))
        store.receive("activity", .object(["revision": .number(3), "phase": .string("heartbeat"),
                                          "text": .string("Waiting on the model (5s)")]))
        XCTAssertNotNil(store.lastEventAt)
        XCTAssertEqual(store.activityDetail, "Waiting on the model (5s)")
        XCTAssertTrue(store.updateLabel.contains("updated"))
        XCTAssertEqual(store.livePhase, "Thinking")
    }
}
