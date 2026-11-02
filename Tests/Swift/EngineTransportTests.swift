import Foundation
import XCTest
@testable import Goblin

final class EngineFrameDecoderTests: XCTestCase {
    func testDecodesFramesAcrossSplitChunksInOrder() throws {
        var decoder = EngineFrameDecoder()
        let first = Data("{\"id\":\"one\",\"result\":{\"text\":\"ok\"}}\n{\"event\":\"stream\",\"data\":{\"te".utf8)
        let second = Data("xt\":\"héllo\"}}\n".utf8)

        let firstFrames = try decoder.append(first)
        XCTAssertEqual(firstFrames.count, 1)
        guard case .message(let firstMessage) = firstFrames[0] else {
            XCTFail("The first complete line should decode as a message.")
            return
        }
        XCTAssertEqual(firstMessage["id"].stringValue, "one")

        let secondFrames = try decoder.append(second)
        XCTAssertEqual(secondFrames.count, 1)
        guard case .message(let secondMessage) = secondFrames[0] else {
            XCTFail("The split UTF-8 line should decode after its final chunk.")
            return
        }
        XCTAssertEqual(secondMessage["event"].stringValue, "stream")
        XCTAssertEqual(secondMessage["data"]["text"].stringValue, "héllo")
    }

    func testMalformedFrameDoesNotDropTheNextFrame() throws {
        var decoder = EngineFrameDecoder()
        let frames = try decoder.append(Data("not json\n{\"event\":\"ready\"}\n".utf8))

        XCTAssertEqual(frames.count, 2)
        guard case .invalid = frames[0] else {
            XCTFail("Malformed JSON should be reported as an invalid frame.")
            return
        }
        guard case .message(let message) = frames[1] else {
            XCTFail("A valid line after a malformed line should still decode.")
            return
        }
        XCTAssertEqual(message["event"].stringValue, "ready")
    }

    func testInvalidUTF8IsRejectedForReaderRecovery() {
        var decoder = EngineFrameDecoder()
        let invalidLine = Data([0x7b, 0x22, 0xc3, 0x28, 0x0a])
        XCTAssertThrowsError(try decoder.append(invalidLine))
    }
}

final class EngineGenerationTests: XCTestCase {
    func testOldProcessTokenStopsOwningTheConnection() {
        var generation = EngineGeneration()
        let first = generation.beginNewProcess()
        let second = generation.beginNewProcess()

        XCTAssertFalse(generation.owns(first))
        XCTAssertTrue(generation.owns(second))
    }
}

final class EnginePipeWriterTests: XCTestCase {
    @MainActor
    func testWritesEveryQueuedFrameInEnqueueOrder() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
        }
        let writer = EnginePipeWriter(handle: pipe.fileHandleForWriting)

        var frames: [Data] = []
        let largePayload = Data(repeating: 0x61, count: 200_000)
        var largeFrame = Data("{\"id\":\"large\",\"result\":\"".utf8)
        largeFrame.append(largePayload)
        largeFrame.append(Data("\"}\n".utf8))
        frames.append(largeFrame)
        for index in 0..<40 {
            let line = "{\"id\":\"request-\(index)\",\"result\":\"payload-\(index)\"}\n"
            frames.append(Data(line.utf8))
        }

        for frame in frames {
            let accepted = writer.enqueue(frame) { _ in }
            XCTAssertTrue(accepted)
        }
        writer.close()

        let received = try await readToEnd(pipe.fileHandleForReading)
        var expected = Data()
        for frame in frames {
            expected.append(frame)
        }
        XCTAssertEqual(received, expected)
    }

    @MainActor
    func testClosedWriterRejectsNewFrames() {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
        }
        let writer = EnginePipeWriter(handle: pipe.fileHandleForWriting)
        writer.close()

        let accepted = writer.enqueue(Data("{}\n".utf8)) { _ in }
        XCTAssertFalse(accepted)
    }
}

private func readToEnd(_ handle: FileHandle) async throws -> Data {
    let task = Task.detached(priority: .userInitiated) {
        try handle.readToEnd() ?? Data()
    }
    return try await task.value
}
