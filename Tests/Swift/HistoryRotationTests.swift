import XCTest
@testable import Goblin

final class HistoryRotationTests: XCTestCase {
    @MainActor
    private func snapshot(_ history: String, revision: Int) -> JSONValue {
        var fields = ReleaseRepairTestSupport.snapshot(revision: revision).objectValue
        fields["history_id"] = .string(history)
        return .object(fields)
    }

    private func page(_ history: String, text: String) -> JSONValue {
        .object([
            "history_id": .string(history), "before": .number(0), "has_more": .bool(false),
            "messages": .array([.object(["id": .string("0"), "i": .number(0),
                                        "kind": .string("agent"), "text": .string(text)])])
        ])
    }

    @MainActor
    func testHistoryChangeClearsOldRowsAndIgnoresOldStream() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(snapshot("first", revision: 1))
        store.mergeHistoryPage(page("first", text: "First history"))
        store.draft = "Keep my unsent draft"
        store.apply(snapshot("second", revision: 2))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "Keep my unsent draft")
        store.mergeHistoryPage(page("second", text: "Second history"))
        store.mergeHistoryPage(page("first", text: "Late first history"))
        store.receive("stream", .object(["history_id": .string("first"),
                                          "kind": .string("agent"), "text": .string("Stale stream")]))
        XCTAssertEqual(store.messages.map(\.text), ["Second history"])
        XCTAssertTrue(store.stream.isEmpty)
    }

    @MainActor
    func testLatePageCannotReplaceNewHistoryWithReusedRecordID() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.apply(snapshot("first", revision: 1))
        store.rpc = { method, params in
            probe.record(method, params)
            if store.historyID == "first" {
                await gate.wait()
                return self.page("first", text: "Old record zero")
            }
            return self.page("second", text: "New record zero")
        }
        let oldRead = Task { await store.loadEarlierHistory() }
        await waitForRPCMethod(probe, "history/page")
        store.apply(snapshot("second", revision: 2))
        store.mergeHistoryPage(page("second", text: "New record zero"))
        await gate.release()
        await oldRead.value
        XCTAssertEqual(store.messages.map(\.text), ["New record zero"])
        XCTAssertEqual(store.historyID, "second")
    }
}
