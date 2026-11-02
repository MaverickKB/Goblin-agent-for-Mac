import Foundation
import XCTest
@testable import Goblin

@MainActor
enum ReleaseRepairTestSupport {
    static func makeStore() throws -> GoblinStore {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try GoblinStore(product: Product.load(from: root),
                               resources: root.appendingPathComponent("Resources"),
                               home: home)
        let connection = store.beginConnection()
        store.finishConnection(.object([:]), generation: connection)
        return store
    }

    static func removeStore(_ store: GoblinStore) {
        try? FileManager.default.removeItem(at: store.home)
    }

    static func snapshot(revision: Int, settingsRevision: Int = 1, ready: Bool = true,
                         busy: Bool = false, activeTurnID: String = "",
                         turns: [JSONValue] = [], messages: [JSONValue] = [],
                         settingsIssue: String = "", setupIssue: String = "",
                         error: String = "", autonomy: Bool = false,
                         agentName: String = "Goblin",
                         settings: [String: JSONValue]? = nil) -> JSONValue {
        let loadedSettings: [String: JSONValue]
        if let settings {
            loadedSettings = settings
        } else {
            loadedSettings = [
                "agent_name": .string(agentName),
                "model": .string("test-model"),
                "model_base_url": .string("http://127.0.0.1/v1")
            ]
        }
        return .object([
            "revision": .number(Double(revision)),
            "settings_revision": .number(Double(settingsRevision)),
            "ready": .bool(ready),
            "busy": .bool(busy),
            "active_turn_id": .string(activeTurnID),
            "turns": .array(turns),
            "messages": .array(messages),
            "settings_issue": .string(settingsIssue),
            "setup_issue": .string(setupIssue),
            "error": .string(error),
            "autonomy": .object(["enabled": .bool(autonomy)]),
            "settings": .object(loadedSettings)
        ])
    }

    static func attachment() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data("attachment".utf8).write(to: url)
        return url
    }

    static func removeAttachment(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class RPCProbe {
    private(set) var methods: [String] = []
    private(set) var parameters: [[String: JSONValue]] = []

    func record(_ method: String, _ params: [String: JSONValue]) {
        methods.append(method)
        parameters.append(params)
    }

    func lastParameters(for method: String) -> [String: JSONValue]? {
        var found: [String: JSONValue]?
        for index in methods.indices {
            if methods[index] == method { found = parameters[index] }
        }
        return found
    }
}

actor AsyncGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

@MainActor
func waitForRPCMethod(_ probe: RPCProbe, _ method: String) async {
    for _ in 0..<2000 {
        if probe.methods.contains(method) { return }
        await Task.yield()
    }
    XCTFail("RPC did not start: " + method)
}
