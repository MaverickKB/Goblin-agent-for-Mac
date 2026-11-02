import XCTest
@testable import Goblin

final class VoiceOutputPolicyTests: XCTestCase {
    func testBuiltInInternalSpeakerIsRejectedByDefault() {
        let speakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .builtIn,
            dataSource: "ispk",
            deviceName: "MacBook Pro Speakers"
        )
        XCTAssertTrue(speakers)
    }

    func testBuiltInHeadphonesAreAllowed() {
        let speakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .builtIn,
            dataSource: "hdpn",
            deviceName: "External Headphones"
        )
        XCTAssertFalse(speakers)
    }

    func testBluetoothOutputIsAllowed() {
        let speakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .bluetooth,
            dataSource: "",
            deviceName: "AirPods Pro"
        )
        XCTAssertFalse(speakers)
    }

    func testUSBOutputIsAllowed() {
        let speakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .usb,
            dataSource: "",
            deviceName: "USB Audio"
        )
        XCTAssertFalse(speakers)
    }

    func testUnknownBuiltInSourceUsesTheDeviceName() {
        let namedSpeakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .builtIn,
            dataSource: "",
            deviceName: "Mac mini Speakers"
        )
        XCTAssertTrue(namedSpeakers)

        let unnamedOutput = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: .builtIn,
            dataSource: "",
            deviceName: "Built-in Output"
        )
        XCTAssertFalse(unnamedOutput)
    }

    func testTransportMappingUsesCoreAudioFourCharacterCodes() {
        XCTAssertEqual(GoblinAudioTransport(fourCC: 0x626C746E), .builtIn)
        XCTAssertEqual(GoblinAudioTransport(fourCC: 0x626C7565), .bluetooth)
        XCTAssertEqual(GoblinAudioTransport(fourCC: nil), .other)
    }

    func testDataSourceDecoding() {
        XCTAssertEqual(GoblinAudioDevice.fourCharacterCode(0x6973706B), "ispk")
        XCTAssertEqual(GoblinAudioDevice.fourCharacterCode(0x6864706E), "hdpn")
        XCTAssertEqual(GoblinAudioDevice.fourCharacterCode(nil), "")
    }
}
