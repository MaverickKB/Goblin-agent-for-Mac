import Foundation
import XCTest
@testable import Goblin

final class HistoryPagingTests: XCTestCase {
    private func row(_ index: Int, _ text: String) -> JSONValue {
        .object(["id": .string(String(index)), "record_i": .number(Double(index)),
                 "kind": .string("user"), "text": .string(text), "turn_id": .string("turn-\(index)")])
    }

    @MainActor
    func testPageAndLiveEventsMergeWithoutGapsOrDuplicatesAndSurviveSnapshots() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.receive("message", row(3, "live"))
        store.mergeHistoryPage(.object(["messages": .array([row(2, "recent"), row(3, "live")]),
                                       "before": .number(2), "has_more": .bool(true)]))
        store.mergeHistoryPage(.object(["messages": .array([row(0, "oldest"), row(1, "older")]),
                                       "before": .number(0), "has_more": .bool(false)]))
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 20, busy: true, activeTurnID: "turn-3"))
        XCTAssertEqual(store.messages.map(\.id), ["0", "1", "2", "3"])
        XCTAssertEqual(store.messages.first?.text, "oldest")
        XCTAssertFalse(store.hasEarlierHistory)
        store.receive("activity", .object(["phase": .string("model_start"), "response_id": .string("response-3")]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("partial")]))
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 21, busy: true, activeTurnID: "turn-3"))
        XCTAssertEqual(store.stream, "partial")
        XCTAssertEqual(store.responseID, "response-3")
    }

    @MainActor
    func testHistoryReadDoesNotPreventStopAndOlderCursorIsUsed() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 1))
        store.mergeHistoryPage(.object(["messages": .array([row(8, "recent")]), "before": .number(8), "has_more": .bool(true)]))
        store.rpc = { method, params in
            probe.record(method, params)
            if method == "history/page" {
                await gate.wait()
                return .object(["messages": .array([]), "before": .number(0), "has_more": .bool(false)])
            }
            return ReleaseRepairTestSupport.snapshot(revision: 2)
        }
        let reader = Task { await store.loadEarlierHistory() }
        await waitForRPCMethod(probe, "history/page")
        await store.stop()
        XCTAssertTrue(probe.methods.contains("chat/stop"))
        XCTAssertTrue(store.loadingHistory)
        XCTAssertEqual(probe.lastParameters(for: "history/page")?["before"]?.numberValue, 8)
        await gate.release()
        await reader.value
        XCTAssertFalse(store.loadingHistory)
    }

    @MainActor
    func testSavedDetailReassemblesSplitUnicodeAndPreservesMetadata() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let text = "漢字🐈 café\n"
        let raw = try JSONEncoder().encode(JSONValue.object(["text": .string(text),
            "meta": .object(["diffs": .array([.object(["patch": .string("+" + text)])]),
                              "attachments": .array([.object(["path": .string("/tmp/exact.txt")])])])]))
        store.rpc = { method, params in
            XCTAssertEqual(method, "history/record")
            let offset = Int(params["offset"]?.numberValue ?? 0)
            let end = min(raw.count, offset + 7)
            return .object(["data": .string(raw.subdata(in: offset..<end).base64EncodedString()),
                            "next_offset": .number(Double(end)), "total": .number(Double(raw.count))])
        }
        await store.readRecord(19)
        XCTAssertTrue(store.recordDetail?.hasPrefix(text) == true)
        XCTAssertTrue(store.recordDetail?.contains("/tmp/exact.txt") == true)
        XCTAssertTrue(store.recordDetail?.contains("diffs") == true)
    }
    @MainActor
    func testExplicitSummaryReadKeepsEverySummaryAcrossBoundedChunks() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let original = String(repeating: "0+1|漢字🐈 summary\n", count: 500)
        let raw = Data(original.utf8)
        store.rpc = { method, params in
            XCTAssertEqual(method, "history/gist")
            let offset = Int(params["offset"]?.numberValue ?? 0)
            let end = min(raw.count, offset + 29)
            return .object(["data": .string(raw.subdata(in: offset..<end).base64EncodedString()),
                            "token": .string("snapshot"), "next_offset": .number(Double(end)),
                            "total": .number(Double(raw.count))])
        }
        await store.loadGistPreview()
        XCTAssertEqual(store.gist, original)
    }

}
