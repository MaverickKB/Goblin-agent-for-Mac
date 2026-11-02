import XCTest
@testable import Goblin

final class VoiceCodecTests: XCTestCase {
    func testRoundTripPreservesSamples() throws {
        let original: [Float] = [0, 0.5, -0.5, 0.25, -0.25]
        let encoded = PCMCodec.base64PCM16LE(fromFloatSamples: original)
        let decoded = try PCMCodec.pcm16LEBase64ToFloat(encoded)
        XCTAssertEqual(decoded.count, original.count)
        for index in 0..<original.count {
            XCTAssertEqual(decoded[index], original[index], accuracy: 0.001)
        }
    }

    func testEncodesHalfScaleAsLittleEndian() {
        let data = PCMCodec.floatToPCM16LE([0.5])
        XCTAssertEqual([UInt8](data), [0x00, 0x40])
    }

    func testDecodesLittleEndianHalfScale() throws {
        let encoded = Data([0x00, 0x40]).base64EncodedString()
        let samples = try PCMCodec.pcm16LEBase64ToFloat(encoded)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
    }

    func testClipsOutOfRangeSamples() {
        let data = PCMCodec.floatToPCM16LE([2.0, -2.0])
        XCTAssertEqual(data.count, 4)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0x7F)
        XCTAssertEqual(bytes[2], 0x01)
        XCTAssertEqual(bytes[3], 0x80)
    }

    func testRejectsOddByteLength() {
        let bad = Data([0x00]).base64EncodedString()
        XCTAssertThrowsError(try PCMCodec.pcm16LEBase64ToFloat(bad)) { error in
            XCTAssertEqual(error as? PCMCodecError, .invalidPCM)
        }
    }

    func testRejectsInvalidBase64() {
        XCTAssertThrowsError(try PCMCodec.pcm16LEBase64ToFloat("not base64!")) { error in
            XCTAssertEqual(error as? PCMCodecError, .invalidBase64)
        }
    }

    func testRejectsEmptyAudio() {
        XCTAssertThrowsError(try PCMCodec.pcm16LEBase64ToFloat("")) { error in
            XCTAssertEqual(error as? PCMCodecError, .invalidPCM)
        }
    }
}
