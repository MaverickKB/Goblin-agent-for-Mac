import Foundation
import Darwin
import XCTest
@testable import Goblin

final class ConnectionRecoveryTests: XCTestCase {
    @MainActor
    func testDisconnectedTurnStaysVisibleWithItsThoughtAndTruthfulControls() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 50, busy: true, activeTurnID: "turn-a"))
        store.receive("message", .object(["id": .string("1"), "kind": .string("user"), "text": .string("Original"), "turn_id": .string("turn-a")]))
        store.receive("activity", .object(["phase": .string("model_start"), "turn_id": .string("turn-a"), "response_id": .string("response-a")]))
        store.receive("stream", .object(["kind": .string("thought"), "text": .string("Observed reasoning")]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("Visible partial reply")]))
        store.receive("activity", .object(["phase": .string("tool"), "text": .string("read_file")]))
        store.receive("approval", .object(["id": .string("approval-a"), "name": .string("write_file")]))
        store.draft = "Keep the draft"
        store.receive("disconnected", .string("Engine exited"))
        XCTAssertFalse(store.busy)
        XCTAssertFalse(store.ready)
        XCTAssertFalse(store.canSend)
        XCTAssertFalse(store.toolActive)
        XCTAssertNil(store.approval)
        XCTAssertEqual(store.liveTurnID, "")
        XCTAssertEqual(store.draft, "Keep the draft")
        XCTAssertEqual(store.localPartialRows.map(\.text), ["Observed reasoning", "Visible partial reply"])
        let turn = try XCTUnwrap(store.turns.first)
        XCTAssertTrue(turn.entries.contains { $0.text == "Visible partial reply" })
        XCTAssertTrue(turn.entries.contains { $0.text == "Observed reasoning" })
        XCTAssertFalse(turn.segments(active: false).isEmpty)
        store.receive("activity", .object(["phase": .string("ready")]))
        XCTAssertEqual(store.livePhase, "Engine stopped")
    }

    @MainActor
    func testFreshBootstrapAcceptsLowRevisionAndReconcilesPartialExactlyOnce() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 99, busy: true, activeTurnID: "turn-a"))
        store.receive("activity", .object(["phase": .string("model_start"), "turn_id": .string("turn-a"), "response_id": .string("response-a")]))
        store.receive("stream", .object(["kind": .string("agent"), "text": .string("Partial")]))
        store.mergeHistoryPage(.object(["messages": .array([]), "before": .number(12), "has_more": .bool(true)]))
        store.receive("disconnected", .string("exited"))
        let generation = store.beginConnection()
        XCTAssertEqual(store.connectionState, .starting)
        XCTAssertNil(store.historyBefore)
        XCTAssertFalse(store.ready)
        XCTAssertTrue(store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation))
        XCTAssertTrue(store.ready)
        let row: JSONValue = .object(["id": .string("7"), "record_i": .number(7), "kind": .string("agent"),
            "turn_id": .string("turn-a"), "response_id": .string("response-a"), "text": .string("Partial"),
            "status": .string("failed"), "final": .bool(false)])
        store.receive("message", row)
        store.mergeHistoryPage(.object(["messages": .array([row]), "before": .number(0), "has_more": .bool(false)]))
        XCTAssertTrue(store.localPartialRows.isEmpty)
        XCTAssertEqual(store.messages.filter { $0.responseID == "response-a" }.count, 1)
        XCTAssertEqual(store.turns.flatMap(\.entries).filter { $0.text == "Partial" }.count, 1)
    }

    @MainActor
    func testLateSubmissionAndRefreshCannotRelabelDisconnectedOrResubmit() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 10))
        store.rpc = { method, params in
            probe.record(method, params)
            await gate.wait()
            return ReleaseRepairTestSupport.snapshot(revision: 100)
        }
        store.draft = "Accepted input"
        let sending = Task { await store.send() }
        await waitForRPCMethod(probe, "chat/send")
        store.draft = "New draft"
        store.receive("disconnected", .string("lost"))
        XCTAssertFalse(store.busy)
        await gate.release()
        await sending.value
        XCTAssertEqual(store.livePhase, "Engine stopped")
        XCTAssertEqual(store.draft, "New draft")
        XCTAssertEqual(store.pendingMessages.first?.text, "Accepted input")
        XCTAssertEqual(probe.methods, ["chat/send"])
        let generation = store.beginConnection()
        XCTAssertTrue(store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation))
        XCTAssertFalse(store.busy)
        XCTAssertEqual(probe.methods, ["chat/send"])
    }

    @MainActor
    func testOldSnapshotReplyDoesNotOverwriteNewConnection() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            await gate.wait()
            return ReleaseRepairTestSupport.snapshot(revision: 100, busy: true, activeTurnID: "old")
        }
        let refreshing = Task { await store.refresh() }
        await waitForRPCMethod(probe, "snapshot")
        store.receive("disconnected", .string("lost"))
        let generation = store.beginConnection()
        store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation)
        await gate.release()
        await refreshing.value
        XCTAssertEqual(store.snapshot["revision"].numberValue, 1)
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.liveTurnID, "")
    }

    @MainActor
    func testNormalHandshakeGatesControlsUntilBootstrapAndRejectsAbandonedAttempt() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.receive("disconnected", .string("lost"))
        let abandoned = store.beginConnection()
        store.receive("disconnected", .string("lost again"))
        XCTAssertFalse(store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 8), generation: abandoned))
        let current = store.beginConnection()
        XCTAssertFalse(store.ready)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 0), generation: current))
        XCTAssertTrue(store.isConnected)
        XCTAssertTrue(store.ready)
    }
    @MainActor
    func testReconnectReapsFailedOwnedChildAndKeepsHealthyReplacement() async throws {
        for brokenPipe in ["stdout", "stdin"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let resources = root.appendingPathComponent("Resources")
            let home = root.appendingPathComponent("Home")
            let executable = resources.appendingPathComponent("Runtime/Python/bin/python3")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(#"{"native_helpers":{"keychain":{"name":"FixtureKeychain"}}}"#.utf8)
                .write(to: resources.appendingPathComponent("product.json"))
            let script = """
            #!/usr/bin/python3
            import json, os, signal, sys, time
            home = os.environ['GOBLIN_HOME']
            marker = os.path.join(home, 'first-pid')
            if not os.path.exists(marker):
                with open(marker, 'w') as saved:
                    saved.write(str(os.getpid()))
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.close(1 if '\(brokenPipe)' == 'stdout' else 0)
                with open(os.path.join(home, 'pipe-closed'), 'w') as ready:
                    ready.write('ready')
                while True:
                    time.sleep(.1)
            for line in sys.stdin:
                request = json.loads(line)
                print(json.dumps({'id': request['id'], 'result': {'pid': os.getpid(), 'ready': True}}), flush=True)
                if request['method'] == 'shutdown':
                    break
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let engine = EngineConnection()
            defer { engine.forceTerminate(); try? FileManager.default.removeItem(at: root) }
            var disconnected = false
            engine.onEvent = { event, _ in if event == "disconnected" { disconnected = true } }
            try await engine.start(resources: resources, home: home)
            if brokenPipe == "stdin" {
                for _ in 0..<500 {
                    if FileManager.default.fileExists(atPath: home.appendingPathComponent("pipe-closed").path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                do {
                    _ = try await engine.call("bootstrap")
                    XCTFail("The closed input pipe must fail the request")
                } catch {}
            }
            for _ in 0..<500 {
                if disconnected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(disconnected)
            XCTAssertFalse(engine.isRunning)
            let oldPID = try XCTUnwrap(Int32(String(contentsOf: home.appendingPathComponent("first-pid"), encoding: .utf8)))
            XCTAssertEqual(kill(oldPID, 0), 0, "Fixture child should still be alive after stdout EOF")
            try await engine.start(resources: resources, home: home)
            let replacement = try await engine.call("bootstrap")
            let replacementPID = Int32(replacement["pid"].numberValue)
            XCTAssertNotEqual(replacementPID, oldPID)
            XCTAssertEqual(kill(oldPID, 0), -1, "The failed child must be reaped before replacement")
            try await engine.start(resources: resources, home: home)
            let same = try await engine.call("bootstrap")
            XCTAssertEqual(Int32(same["pid"].numberValue), replacementPID)
            await engine.shutdown()
        }
    }

    @MainActor
    func testOldDetailAndSummaryReadsCannotClearNewLoadingStateOrOverwriteContent() async throws {
        for method in ["history/record", "history/gist"] {
            let store = try ReleaseRepairTestSupport.makeStore()
            defer { ReleaseRepairTestSupport.removeStore(store) }
            let oldGate = AsyncGate()
            let newGate = AsyncGate()
            let probe = RPCProbe()
            var calls = 0
            store.rpc = { name, params in
                probe.record(name, params)
                calls += 1
                let call = calls
                if call == 1 { await oldGate.wait() } else { await newGate.wait() }
                let text = call == 1 ? "old" : "new"
                let data: Data
                if method == "history/record" {
                    data = try JSONEncoder().encode(JSONValue.object(["text": .string(text)]))
                } else { data = Data(text.utf8) }
                return .object(["data": .string(data.base64EncodedString()), "next_offset": .number(Double(data.count)),
                                "total": .number(Double(data.count)), "token": .string("read")])
            }
            let old = Task {
                if method == "history/record" { await store.readRecord(1) }
                else { await store.loadGistPreview() }
            }
            await waitForRPCMethod(probe, method)
            store.receive("disconnected", .string("lost"))
            let generation = store.beginConnection()
            store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation)
            let current = Task {
                if method == "history/record" { await store.readRecord(1) }
                else { await store.loadGistPreview() }
            }
            for _ in 0..<2000 {
                if calls == 2 { break }
                await Task.yield()
            }
            XCTAssertEqual(calls, 2)
            await oldGate.release()
            await old.value
            if method == "history/record" {
                XCTAssertTrue(store.loadingRecord)
                XCTAssertNil(store.recordDetail)
            } else {
                XCTAssertTrue(store.loadingGist)
                XCTAssertEqual(store.gist, "")
            }
            await newGate.release()
            await current.value
            if method == "history/record" { XCTAssertEqual(store.recordDetail, "new") }
            else { XCTAssertEqual(store.gist, "new") }
        }
    }

    @MainActor
    func testQueuedCompactionRefreshDoesNotLaunchInReplacementConnection() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let probe = RPCProbe()
        store.rpc = { method, params in
            probe.record(method, params)
            return ReleaseRepairTestSupport.snapshot(revision: 99)
        }
        store.receive("compaction", .object(["ready": .bool(true)]))
        store.receive("disconnected", .string("lost"))
        let generation = store.beginConnection()
        store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(probe.methods.isEmpty)
        XCTAssertEqual(store.snapshot["revision"].numberValue, 1)
    }

    @MainActor
    func testOldApprovalResolutionCannotClearReplacementApproval() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let gate = AsyncGate()
        let probe = RPCProbe()
        store.receive("approval", .object(["id": .string("old"), "name": .string("write_file")]))
        store.rpc = { method, params in
            probe.record(method, params)
            await gate.wait()
            return .object([:])
        }
        let resolving = Task { await store.resolveApproval(true) }
        await waitForRPCMethod(probe, "approval/resolve")
        store.receive("disconnected", .string("lost"))
        let generation = store.beginConnection()
        store.finishConnection(ReleaseRepairTestSupport.snapshot(revision: 1), generation: generation)
        store.receive("approval", .object(["id": .string("new"), "name": .string("read_file")]))
        await gate.release()
        await resolving.value
        XCTAssertEqual(store.approval?["id"].stringValue, "new")
        XCTAssertEqual(probe.lastParameters(for: "approval/resolve")?["id"]?.stringValue, "old")
    }

}
