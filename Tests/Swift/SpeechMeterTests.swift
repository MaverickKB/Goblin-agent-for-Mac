import AVFoundation
import XCTest
@testable import Goblin

final class SpeechMeterTests: XCTestCase {
    func testPresentationLatencyDelaysMouthAndStalePCMClosesIt() {
        let meter = SpeechMeter()
        meter.record(level: 0.7, renderedAt: 10, latency: 0.2)
        XCTAssertEqual(meter.level(at: 10.1), 0)
        XCTAssertEqual(meter.level(at: 10.21), 0.7)
        XCTAssertEqual(meter.level(at: 10.31), 0)
    }

    func testInterruptRejectsLatePCMAndNewSpeechCanResume() {
        let meter = SpeechMeter()
        meter.record(level: 0.8, renderedAt: 10, latency: 0)
        meter.clear(at: 10.01)
        meter.record(level: 0.6, renderedAt: 10, latency: 0.2)
        XCTAssertEqual(meter.level(at: 10.03), 0)
        meter.record(level: 0.5, renderedAt: 10.1, latency: 0)
        XCTAssertEqual(meter.level(at: 10.11), 0.5)
    }

    func testLargeRenderBuffersPreserveSilenceAndSyllableTiming() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let window = Int(format.sampleRate * 0.02)
        let count = window * 10
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<count {
            let voiced = index >= window * 2 && index < window * 8
            channel[index] = voiced ? 0.1 : 0
        }
        let meter = SpeechMeter()
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10))
        meter.record(buffer, at: time, latency: 0.1)
        XCTAssertEqual(meter.level(at: 10.05), 0)
        XCTAssertEqual(meter.level(at: 10.11), 0)
        XCTAssertGreaterThan(meter.level(at: 10.15), 0.3)
        XCTAssertGreaterThan(meter.level(at: 10.25), 0.3)
        XCTAssertEqual(meter.level(at: 10.29), 0)
        XCTAssertEqual(meter.level(at: 10.5), 0)
        meter.clear(at: 10.01)
        meter.record(buffer, at: time, latency: 0.2)
        XCTAssertEqual(meter.level(at: 10.28), 0, "Late cancelled buffers cannot reopen the jaw")
    }

    func testMissingHostTimeUsesTheLivePresentationClock() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<480 { channel[index] = 0.1 }
        let meter = SpeechMeter()
        meter.record(buffer, at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate), latency: 0)
        XCTAssertGreaterThan(meter.level(), 0.3)
    }

    func testMeterReadsRenderedSamplesAndSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<512 { channel[index] = 0 }
        XCTAssertEqual(SpeechMeter.measure(buffer), 0)
        for index in 0..<512 { channel[index] = Float(sin(Double(index) * 0.1) * 0.1) }
        XCTAssertGreaterThan(SpeechMeter.measure(buffer), 0.2)
        XCTAssertLessThan(SpeechMeter.measure(buffer), 0.5)
    }
}
