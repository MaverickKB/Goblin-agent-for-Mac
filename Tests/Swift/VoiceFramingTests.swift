import XCTest
@testable import Goblin

final class VoiceFramingTests: XCTestCase {
    func testAudioFrameCarriesPCM16Append() throws {
        let pcm = Data([0x00, 0x40, 0x01, 0x80])
        guard let frame = GoblinVoiceFrame.audio(pcm) else {
            return XCTFail("A non-empty chunk must produce a frame")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(frame.text.utf8))
        XCTAssertEqual(value["type"].stringValue, "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: value["audio"].stringValue), pcm)
        XCTAssertEqual(frame.byteCount, frame.text.utf8.count)
    }

    func testEmptyAudioProducesNoFrame() {
        XCTAssertNil(GoblinVoiceFrame.audio(Data()))
    }

    func testControlFrameRoundTripsJSON() throws {
        let value: JSONValue = .object([
            "type": .string("response.create"),
            "event_id": .string("event-1")
        ])
        guard let frame = GoblinVoiceFrame.make(value) else {
            return XCTFail("A JSON value must produce a frame")
        }
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(frame.text.utf8))
        XCTAssertEqual(decoded, value)
    }

    func testOutboxPreservesOrderAndCloses() async {
        let outbox = GoblinVoiceOutbox(maxBytes: 1_000)
        XCTAssertTrue(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "one", byteCount: 10)))
        XCTAssertTrue(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "two", byteCount: 20)))
        XCTAssertTrue(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "three", byteCount: 30)))
        outbox.close()
        XCTAssertFalse(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "late", byteCount: 1)))

        var texts: [String] = []
        for await frame in outbox.frames {
            texts.append(frame.text)
        }
        XCTAssertEqual(texts, ["one", "two", "three"])
    }

    func testOutboxEnforcesByteBudgetUntilReleased() {
        let outbox = GoblinVoiceOutbox(maxBytes: 100)
        XCTAssertTrue(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "first", byteCount: 60)))
        XCTAssertFalse(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "second", byteCount: 50)))
        outbox.release(bytes: 60)
        XCTAssertTrue(outbox.enqueue(GoblinVoiceOutbox.Frame(text: "second", byteCount: 50)))
    }
}
