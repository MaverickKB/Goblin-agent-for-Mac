// PCM16 audio conversion for Goblin voice.
//
// See Runtime/NOTICE.
// Provider frames contain mono, 24 kHz, signed 16-bit little-endian PCM.

import Foundation

/// Conversion between Float32 samples and the provider's PCM16 little-endian bytes.
enum PCMCodec {
    /// Convert mono Float32 samples in [-1, 1] to little-endian PCM16 bytes.
    static func floatToPCM16LE(_ samples: [Float]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * 2)
        var index = 0
        while index < samples.count {
            let clipped = max(-1.0, min(1.0, samples[index]))
            let scaled = Int16((clipped * 32767.0).rounded())
            let value = scaled.littleEndian
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            index += 1
        }
        return Data(bytes)
    }

    /// Decode base64 PCM16 little-endian mono into Float32 samples.
    static func pcm16LEBase64ToFloat(_ encoded: String) throws -> [Float] {
        guard let data = Data(base64Encoded: encoded) else {
            throw PCMCodecError.invalidBase64
        }
        if data.isEmpty || data.count % 2 != 0 {
            throw PCMCodecError.invalidPCM
        }
        let bytes = [UInt8](data)
        let sampleCount = bytes.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        var index = 0
        while index < sampleCount {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1])
            let raw = Int16(bitPattern: low | (high << 8))
            samples[index] = Float(raw) / 32768.0
            index += 1
        }
        return samples
    }

    /// Encode Float32 samples as the base64 PCM16 string the provider expects.
    static func base64PCM16LE(fromFloatSamples samples: [Float]) -> String {
        let data = floatToPCM16LE(samples)
        return data.base64EncodedString()
    }
}

enum PCMCodecError: Error, Equatable {
    case invalidBase64
    case invalidPCM
}
