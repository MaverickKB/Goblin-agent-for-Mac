import XCTest
@testable import Goblin

final class VoiceEventFilterTests: XCTestCase {
    func testBridgesTheSpeakersFinalTranscript() {
        let event: JSONValue = .object([
            "type": .string("conversation.item.input_audio_transcription.completed"),
            "item_id": .string("item-1"),
            "transcript": .string("Read the build log."),
            "content_index": .number(0)
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("The speaker transcript must reach the engine")
        }
        XCTAssertEqual(bridged["type"].stringValue, "conversation.item.input_audio_transcription.completed")
        XCTAssertEqual(bridged["item_id"].stringValue, "item-1")
        XCTAssertEqual(bridged["transcript"].stringValue, "Read the build log.")
        XCTAssertEqual(bridged["content_index"].numberValue, 0)
    }

    func testNormalizesTheLegacyAgentTranscriptName() {
        let event: JSONValue = .object([
            "type": .string("response.audio_transcript.done"),
            "item_id": .string("assistant-1"),
            "transcript": .string("The build is green.")
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("The agent transcript must reach the engine")
        }
        XCTAssertEqual(bridged["type"].stringValue, "response.output_audio_transcript.done")
        XCTAssertEqual(bridged["item_id"].stringValue, "assistant-1")
        XCTAssertEqual(bridged["transcript"].stringValue, "The build is green.")
    }

    func testDropsAudioDeltas() {
        let event: JSONValue = .object([
            "type": .string("response.output_audio.delta"),
            "delta": .string("AAAA")
        ])
        XCTAssertNil(GoblinVoiceEventFilter.bridgeEvent(from: event))
    }

    func testDropsNonIntegerContentIndex() {
        let event: JSONValue = .object([
            "type": .string("conversation.item.input_audio_transcription.completed"),
            "item_id": .string("item-1"),
            "transcript": .string("Hello."),
            "content_index": .number(1.5)
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("The transcript itself is valid")
        }
        XCTAssertEqual(bridged["content_index"], .null)
    }

    func testKeepsToolCallArguments() {
        let event: JSONValue = .object([
            "type": .string("response.function_call_arguments.done"),
            "call_id": .string("call-1"),
            "response_id": .string("resp-1"),
            "name": .string("session_task"),
            "arguments": .string("{\"action\":\"submit\",\"text\":\"Check the build\"}")
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("The tool call must reach the engine")
        }
        XCTAssertEqual(bridged["name"].stringValue, "session_task")
        XCTAssertEqual(bridged["call_id"].stringValue, "call-1")
        XCTAssertEqual(bridged["response_id"].stringValue, "resp-1")
        XCTAssertEqual(bridged["arguments"].stringValue, "{\"action\":\"submit\",\"text\":\"Check the build\"}")
    }

    func testSanitizesResponseDone() {
        let event: JSONValue = .object([
            "type": .string("response.done"),
            "response": .object([
                "id": .string("resp-1"),
                "status": .string("completed"),
                "output": .array([
                    .object([
                        "type": .string("function_call"),
                        "call_id": .string("call-1"),
                        "name": .string("session_task")
                    ]),
                    .object(["type": .string("message")])
                ]),
                "extra": .string("drop-me")
            ])
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("response.done must reach the engine")
        }
        let response = bridged["response"]
        XCTAssertEqual(response["id"].stringValue, "resp-1")
        XCTAssertEqual(response["status"].stringValue, "completed")
        XCTAssertEqual(response["extra"], .null)
        let output = response["output"].arrayValue
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0]["call_id"].stringValue, "call-1")
        XCTAssertEqual(output[0]["name"], .null)
    }

    func testDropsUnknownStatusOnResponseDone() {
        let event: JSONValue = .object([
            "type": .string("response.done"),
            "response": .object([
                "id": .string("resp-1"),
                "status": .string("mystery")
            ])
        ])
        guard let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) else {
            return XCTFail("response.done must reach the engine")
        }
        XCTAssertEqual(bridged["response"]["status"], .null)
    }

    func testTranscriptUpdateSeparatesRoles() {
        let speaker = GoblinVoiceEventFilter.transcriptUpdate(from: .object([
            "type": .string("conversation.item.input_audio_transcription.completed"),
            "transcript": .string("Please inspect the task.")
        ]))
        XCTAssertEqual(speaker?.role, "user")
        XCTAssertEqual(speaker?.text, "Please inspect the task.")

        let agent = GoblinVoiceEventFilter.transcriptUpdate(from: .object([
            "type": .string("response.output_audio_transcript.done"),
            "transcript": .string("Inspection complete.")
        ]))
        XCTAssertEqual(agent?.role, "agent")
        XCTAssertEqual(agent?.text, "Inspection complete.")
    }

    func testTranscriptUpdateIgnoresDeltas() {
        let delta = GoblinVoiceEventFilter.transcriptUpdate(from: .object([
            "type": .string("response.output_audio_transcript.delta"),
            "delta": .string("partial")
        ]))
        XCTAssertNil(delta)
    }
}
