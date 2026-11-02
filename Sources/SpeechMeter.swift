import AVFoundation
import Foundation
import os
import QuartzCore

final class SpeechMeter: Sendable {
    private struct Sample: Sendable {
        var time = 0.0
        var level = 0.0
    }

    private struct Storage: Sendable {
        var samples = Array(repeating: Sample(), count: 128)
        var next = 0
        var count = 0
        var clearedAt = 0.0
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    func record(level: Double, renderedAt: Double, latency: Double, bufferStartedAt: Double? = nil) {
        _ = storage.withLockIfAvailable { state in
            if (bufferStartedAt ?? renderedAt) < state.clearedAt { return }
            let sample = Sample(time: renderedAt + max(0, latency), level: max(0, min(level, 1)))
            state.samples[state.next] = sample
            state.next = (state.next + 1) % state.samples.count
            state.count = min(state.count + 1, state.samples.count)
        }
    }

    func record(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, latency: Double) {
        let rate = buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        if rate <= 0 || count == 0 { return }
        var renderedAt = CACurrentMediaTime()
        if time.isHostTimeValid {
            renderedAt = AVAudioTime.seconds(forHostTime: time.hostTime)
        }
        // Tap sizes are advisory; preserve syllable timing inside larger buffers.
        let window = max(1, Int(rate * 0.02))
        var offset = 0
        while offset < count {
            let end = min(offset + window, count)
            let level = Self.measure(buffer, from: offset, to: end)
            record(level: level, renderedAt: renderedAt + Double(offset) / rate,
                   latency: latency, bufferStartedAt: renderedAt)
            offset = end
        }
    }

    func level(at time: Double = CACurrentMediaTime()) -> Double {
        storage.withLock { state in
            for offset in 0..<state.count {
                let index = (state.next - 1 - offset + state.samples.count) % state.samples.count
                let sample = state.samples[index]
                if sample.time > time { continue }
                if time - sample.time > 0.09 { return 0 }
                return sample.level
            }
            return 0
        }
    }

    func clear(at time: Double = CACurrentMediaTime()) {
        storage.withLock { state in
            state.count = 0
            state.next = 0
            state.clearedAt = time
        }
    }

    static func measure(_ buffer: AVAudioPCMBuffer, from start: Int = 0, to end: Int? = nil) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let last = max(0, min(end ?? Int(buffer.frameLength), Int(buffer.frameLength)))
        let first = max(0, min(start, last))
        let count = last - first
        if count == 0 { return 0 }
        var sum = 0.0
        for index in first..<last {
            let sample = Double(channel[index])
            sum += sample * sample
        }
        let rms = sqrt(sum / Double(count))
        return max(0, min(1, (rms - 0.008) * 5))
    }
}
