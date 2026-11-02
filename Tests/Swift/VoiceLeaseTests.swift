import XCTest
@testable import Goblin

final class VoiceLeaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAcceptsXAIShapedLease() throws {
        let lease = try GoblinVoiceLease(response: makeLease(), now: now)
        XCTAssertEqual(lease.id, "lease-1")
        XCTAssertEqual(lease.protocols, ["xai-client-secret.token"])
        XCTAssertEqual(lease.sampleRate, 24_000)
        XCTAssertEqual(lease.shape, .xai)
        XCTAssertEqual(lease.websocketURL.host, "api.x.ai")
        XCTAssertEqual(lease.sessionExpiresAt.timeIntervalSince1970, now.timeIntervalSince1970 + 300)
        XCTAssertEqual(lease.sessionUpdate["type"].stringValue, "session.update")
    }

    func testAcceptsNestedOpenAITurnDetection() throws {
        let lease = try GoblinVoiceLease(response: makeLease(nestedTurnDetection: true), now: now)
        XCTAssertEqual(lease.shape, .openai)
    }

    func testAcceptsBareSessionFieldFromBridgeContract() throws {
        let response = makeLease(includeSessionUpdate: false)
        let lease = try GoblinVoiceLease(response: response, now: now)
        XCTAssertEqual(lease.sessionUpdate["type"].stringValue, "session.update")
        XCTAssertEqual(lease.sessionUpdate["session"]["instructions"].stringValue, "Shared instructions.")
    }

    func testFallsBackToPlainIDField() throws {
        let lease = try GoblinVoiceLease(response: makeLease(voiceID: nil, plainID: "plain-7"), now: now)
        XCTAssertEqual(lease.id, "plain-7")
    }

    func testRejectsMissingID() {
        XCTAssertThrowsError(try GoblinVoiceLease(response: makeLease(voiceID: nil), now: now)) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The engine returned a voice lease without an id."
            )
        }
    }

    func testRejectsHTTPSWebSocket() {
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(url: "https://api.x.ai/v1/realtime"), now: now)
        ) { error in
            XCTAssertEqual((error as? GoblinVoiceError)?.message, "The voice WebSocket must use ws or wss.")
        }
    }

    func testRejectsCredentialBearingWebSocket() {
        let url = "wss://user:secret@api.x.ai/v1/realtime"
        XCTAssertThrowsError(try GoblinVoiceLease(response: makeLease(url: url), now: now))
    }

    func testRejectsEmptyProtocols() {
        XCTAssertThrowsError(try GoblinVoiceLease(response: makeLease(protocols: []), now: now)) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The voice lease did not include a provider subprotocol."
            )
        }
    }

    func testRejectsExpiredLease() {
        let expired = now.timeIntervalSince1970 - 1
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(expiresAt: expired), now: now)
        ) { error in
            XCTAssertEqual((error as? GoblinVoiceError)?.message, "The voice lease has expired. Start voice again.")
        }
    }

    func testRejectsExpiredSession() {
        let expired = now.timeIntervalSince1970 - 1
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(sessionExpiresAt: expired), now: now)
        )
    }

    func testRejectsFormatRateMismatch() {
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(formatRate: 48_000), now: now)
        ) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The voice session audio rate does not match the lease."
            )
        }
    }

    func testRejectsNonPCMFormat() {
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(formatType: "audio/opus"), now: now)
        ) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The voice session does not use PCM audio for input."
            )
        }
    }

    func testRejectsMissingInstructions() {
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(includeInstructions: false), now: now)
        ) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The voice session update is missing its shared instructions."
            )
        }
    }

    func testRejectsMissingTurnDetection() {
        XCTAssertThrowsError(
            try GoblinVoiceLease(response: makeLease(turnDetection: false), now: now)
        ) { error in
            XCTAssertEqual(
                (error as? GoblinVoiceError)?.message,
                "The voice session does not use server voice activity detection."
            )
        }
    }

    // MARK: Builders

    private func makeLease(
        voiceID: String? = "lease-1",
        plainID: String? = nil,
        url: String = "wss://api.x.ai/v1/realtime?model=grok-voice-latest",
        protocols: [String] = ["xai-client-secret.token"],
        expiresAt: Double? = nil,
        sessionExpiresAt: Double? = nil,
        rate: Double = 24_000,
        formatRate: Double? = nil,
        formatType: String = "audio/pcm",
        nestedTurnDetection: Bool = false,
        turnDetection: Bool = true,
        includeInstructions: Bool = true,
        includeSessionUpdate: Bool = true
    ) -> JSONValue {
        var session: [String: JSONValue] = [
            "audio": .object([
                "input": .object([
                    "format": .object([
                        "type": .string(formatType),
                        "rate": .number(formatRate ?? rate)
                    ]),
                    "transport": .string("json")
                ]),
                "output": .object([
                    "format": .object([
                        "type": .string(formatType),
                        "rate": .number(formatRate ?? rate)
                    ]),
                    "transport": .string("json")
                ])
            ])
        ]
        if includeInstructions {
            session["instructions"] = .string("Shared instructions.")
        }
        if turnDetection {
            let detection: JSONValue = .object(["type": .string("server_vad")])
            if nestedTurnDetection {
                let audioValue = session["audio"] ?? .null
                var audio = audioValue.objectValue
                var input = audio["input"]?.objectValue ?? [:]
                input["turn_detection"] = detection
                audio["input"] = .object(input)
                session["audio"] = .object(audio)
            } else {
                session["turn_detection"] = detection
            }
        }
        var response: [String: JSONValue] = [
            "websocket_url": .string(url),
            "protocols": .array(protocols.map { .string($0) }),
            "expires_at": .number(expiresAt ?? now.timeIntervalSince1970 + 60),
            "session_expires_at": .number(sessionExpiresAt ?? now.timeIntervalSince1970 + 300),
            "max_session_seconds": .number(300),
            "audio_sample_rate": .number(rate),
            "audio_format": .string("audio/pcm")
        ]
        if let voiceID {
            response["voice_id"] = .string(voiceID)
        }
        if let plainID {
            response["id"] = .string(plainID)
        }
        if includeSessionUpdate {
            response["session_update"] = .object([
                "type": .string("session.update"),
                "session": .object(session)
            ])
        } else {
            response["session"] = .object(session)
        }
        return .object(response)
    }
}
