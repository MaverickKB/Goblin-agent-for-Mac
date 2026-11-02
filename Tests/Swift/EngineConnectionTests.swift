import Foundation
import XCTest
@testable import Goblin

final class PipeLineBufferTests: XCTestCase {
    func testPreservesSplitUTF8AndMultipleFrames() throws {
        var buffer = PipeLineBuffer()
        let bytes = Data("{\"text\":\"héllo\"}\n{\"id\":\"second\"}\n".utf8)
        let split = bytes.firstIndex(of: 0xc3)!
        let first = try buffer.append(bytes[...split])
        XCTAssertTrue(first.isEmpty)
        let second = try buffer.append(bytes[(split + 1)...])
        XCTAssertEqual(second, ["{\"text\":\"héllo\"}", "{\"id\":\"second\"}"])
    }
}

final class EngineConnectionTests: XCTestCase {
    @MainActor
    func testInstalledEngineRespondsWhileStderrIsSilent() async throws {
        guard let configured = ProcessInfo.processInfo.environment["GOBLIN_TEST_RESOURCES"] else {
            throw XCTSkip("Set GOBLIN_TEST_RESOURCES to a packaged app's Resources directory.")
        }
        let resources = URL(fileURLWithPath: configured)
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Runtime/Python/bin/python3").path) else {
            throw XCTSkip("Set GOBLIN_TEST_RESOURCES to a packaged app's Resources directory.")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-native-pipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("cache"), withIntermediateDirectories: true)
        let engine = EngineConnection()
        defer {
            engine.forceTerminate()
            try? FileManager.default.removeItem(at: home)
        }
        try await engine.start(resources: resources, home: home)
        var exceededDeadline = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            exceededDeadline = true
            engine.forceTerminate()
        }
        defer { deadline.cancel() }
        let snapshot = try await engine.call("bootstrap")
        XCTAssertFalse(exceededDeadline, "Silent stderr blocked the stdout response.")
        XCTAssertFalse(snapshot["tools"].arrayValue.isEmpty)
        XCTAssertEqual(snapshot["settings"]["agent_name"].stringValue, "Goblin")
        await engine.shutdown()
        XCTAssertFalse(engine.isRunning)
        let replacement = EngineConnection()
        try await replacement.start(resources: resources, home: home)
        let reopened = try await replacement.call("bootstrap")
        XCTAssertFalse(reopened["tools"].arrayValue.isEmpty)
        await replacement.shutdown()
    }
}
