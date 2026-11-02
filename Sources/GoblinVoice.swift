// Goblin native duplex voice for this Mac app.
//
// See Runtime/NOTICE.
//
// This file is the Mac voice engine:
// - No CallKit and no AVAudioSession. The Mac app owns one AVAudioEngine.
// - The engine pipe supplies the lease, tools and instructions. This file never
//   builds model state, tool schemas or history.
// - Every transcript, tool call, task completion and provider response travels
//   through EngineConnection with voice/events, so the shared session answers.
// - The provider socket and all audio stay native. No secret is read here.

import AVFoundation
import CoreAudio
import Foundation
import Observation

// MARK: - Errors, phases and display state

struct GoblinVoiceError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

enum GoblinVoicePhase: String {
    case idle
    case starting
    case connecting
    case listening
    case speaking
    case muted
    case error
}

/// Display-only caption. The engine's chat log remains the authoritative history.
struct GoblinVoiceTranscript: Equatable, Sendable {
    let role: String
    let text: String
}

private enum GoblinVoiceEnding {
    case stopped
    case failed(String)
}

// MARK: - Output device policy

enum GoblinAudioTransport: String, Sendable {
    case builtIn
    case bluetooth
    case usb
    case hdmi
    case displayPort
    case airPlay
    case virtual
    case thunderbolt
    case aggregate
    case other

    init(fourCC: UInt32?) {
        guard let fourCC else {
            self = .other
            return
        }
        switch fourCC {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            self = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            self = .aggregate
        default:
            self = .other
        }
    }
}

struct GoblinAudioOutput: Sendable, Equatable {
    let name: String
    let transport: GoblinAudioTransport
    let dataSource: String
    let usesBuiltInSpeakers: Bool
}

enum GoblinAudioOutputPolicy {
    static let internalSpeakerSource = "ispk"
    static let headphoneSource = "hdpn"

    /// A built-in output is speakers unless CoreAudio reports headphones.
    static func usesBuiltInSpeakers(
        transport: GoblinAudioTransport,
        dataSource: String,
        deviceName: String
    ) -> Bool {
        if transport != .builtIn {
            return false
        }
        if dataSource == internalSpeakerSource {
            return true
        }
        if dataSource == headphoneSource {
            return false
        }
        // Some built-in outputs expose no data source. The device name is the
        // remaining evidence, and only a speaker name counts as speakers.
        return deviceName.lowercased().contains("speaker")
    }
}

enum GoblinAudioDevice {
    static func defaultOutput() -> GoblinAudioOutput? {
        guard let device = defaultOutputDevice() else {
            return nil
        }
        let name = deviceName(device)
        let transport = GoblinAudioTransport(
            fourCC: readUInt32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        )
        // Data source is an output-scope property. Reading it in the global scope
        // fails on Macs that report ispk or hdpn here.
        let dataSource = fourCharacterCode(
            readUInt32(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        )
        let speakers = GoblinAudioOutputPolicy.usesBuiltInSpeakers(
            transport: transport,
            dataSource: dataSource,
            deviceName: name
        )
        return GoblinAudioOutput(
            name: name,
            transport: transport,
            dataSource: dataSource,
            usesBuiltInSpeakers: speakers
        )
    }

    static func fourCharacterCode(_ value: UInt32?) -> String {
        guard let value else {
            return ""
        }
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        var text = ""
        for byte in bytes {
            if byte >= 32 && byte < 127 {
                text.append(Character(UnicodeScalar(byte)))
            }
        }
        return text
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(
            kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &value
        )
        if status != noErr {
            return nil
        }
        return value
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = propertyAddress(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        if status != noErr {
            return ""
        }
        return name as String
    }

    private static func readUInt32(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(selector, scope: scope)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        if status != noErr {
            return nil
        }
        return value
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

// MARK: - Lease

enum GoblinVoiceSessionShape: String, Sendable {
    case xai
    case openai
}

/// The source lease returned by voice/start, read and validated before use.
struct GoblinVoiceLease: Sendable {
    let id: String
    let websocketURL: URL
    let protocols: [String]
    let sessionExpiresAt: Date
    let sampleRate: Double
    let sessionUpdate: JSONValue
    let shape: GoblinVoiceSessionShape

    /// Read the id even from a lease that later fails validation, so it can be closed.
    static func identifier(in response: JSONValue) -> String {
        let voiceID = response["voice_id"].stringValue
        if voiceID.isEmpty == false {
            return voiceID
        }
        return response["id"].stringValue
    }

    init(response: JSONValue, now: Date = Date()) throws {
        let id = Self.identifier(in: response)
        if id.isEmpty {
            throw GoblinVoiceError("The engine returned a voice lease without an id.")
        }

        let urlText = response["websocket_url"].stringValue
        guard let url = URL(string: urlText) else {
            throw GoblinVoiceError("The voice lease did not include a WebSocket address.")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "ws" && scheme != "wss" {
            throw GoblinVoiceError("The voice WebSocket must use ws or wss.")
        }
        if url.user != nil || url.password != nil {
            throw GoblinVoiceError("The voice WebSocket address must not carry credentials.")
        }
        if url.fragment != nil {
            throw GoblinVoiceError("The voice WebSocket address must not carry a fragment.")
        }

        let protocols = response["protocols"].arrayValue.map { $0.stringValue }
        if protocols.isEmpty {
            throw GoblinVoiceError("The voice lease did not include a provider subprotocol.")
        }
        for value in protocols {
            if value.isEmpty {
                throw GoblinVoiceError("The voice lease included an empty provider subprotocol.")
            }
        }

        let seconds = now.timeIntervalSince1970
        let expiresAt = response["expires_at"].numberValue
        if expiresAt <= 0 {
            throw GoblinVoiceError("The voice lease is missing its expiry time.")
        }
        if expiresAt <= seconds {
            throw GoblinVoiceError("The voice lease has expired. Start voice again.")
        }
        let sessionExpiresAt = response["session_expires_at"].numberValue
        if sessionExpiresAt <= 0 {
            throw GoblinVoiceError("The voice lease is missing its session expiry time.")
        }
        if sessionExpiresAt <= seconds {
            throw GoblinVoiceError("The voice session time has already run out. Start voice again.")
        }
        if response["max_session_seconds"].numberValue <= 0 {
            throw GoblinVoiceError("The voice lease is missing its session time limit.")
        }

        let sampleRate = response["audio_sample_rate"].numberValue
        if sampleRate <= 0 {
            throw GoblinVoiceError("The voice lease did not declare its audio sample rate.")
        }

        var sessionUpdate = response["session_update"]
        if sessionUpdate["type"].stringValue != "session.update" {
            // BRIDGE.md calls the lease field "session"; the source returns a full
            // session.update. Accept the bare session under the same contract.
            if case .object = response["session"] {
                sessionUpdate = .object([
                    "type": .string("session.update"),
                    "session": response["session"]
                ])
            }
        }
        if sessionUpdate["type"].stringValue != "session.update" {
            throw GoblinVoiceError("The voice lease did not include a session update.")
        }
        let session = sessionUpdate["session"]
        if case .object = session {
            // The session object is present.
        } else {
            throw GoblinVoiceError("The voice session update is malformed.")
        }
        if case .string = session["instructions"] {
            // The engine owns the handoff instructions. Empty is still owned text.
        } else {
            throw GoblinVoiceError("The voice session update is missing its shared instructions.")
        }

        let topLevelTurn = session["turn_detection"]["type"].stringValue
        let nestedTurn = session["audio"]["input"]["turn_detection"]["type"].stringValue
        let shape: GoblinVoiceSessionShape
        if topLevelTurn == "server_vad" {
            shape = .xai
        } else if nestedTurn == "server_vad" {
            shape = .openai
        } else {
            throw GoblinVoiceError("The voice session does not use server voice activity detection.")
        }

        for direction in ["input", "output"] {
            let audio = session["audio"][direction]
            let format = audio["format"]
            if format["type"].stringValue != "audio/pcm" {
                throw GoblinVoiceError("The voice session does not use PCM audio for " + direction + ".")
            }
            if format["rate"].numberValue != sampleRate {
                throw GoblinVoiceError("The voice session audio rate does not match the lease.")
            }
            let transport = audio["transport"].stringValue
            if transport.isEmpty == false && transport != "json" {
                throw GoblinVoiceError("The voice session does not use JSON audio transport.")
            }
        }

        self.id = id
        self.websocketURL = url
        self.protocols = protocols
        self.sessionExpiresAt = Date(timeIntervalSince1970: sessionExpiresAt)
        self.sampleRate = sampleRate
        self.sessionUpdate = sessionUpdate
        self.shape = shape
    }
}

// MARK: - Provider event shaping

enum GoblinVoiceEventFilter {
    private static let bridgedTypes: Set<String> = [
        "input_audio_buffer.committed",
        "conversation.item.input_audio_transcription.completed",
        "response.output_audio_transcript.done",
        "response.audio_transcript.done",
        "response.function_call_arguments.done",
        "response.done"
    ]

    private static let stringKeys = [
        "event_id",
        "item_id",
        "response_id",
        "call_id",
        "name",
        "arguments",
        "transcript"
    ]

    private static let integerKeys = ["content_index", "output_index"]

    /// Keep only the fields the engine validates. Everything else stays native.
    static func bridgeEvent(from event: JSONValue) -> JSONValue? {
        let type = event["type"].stringValue
        if bridgedTypes.contains(type) == false {
            return nil
        }
        var fields: [String: JSONValue] = [:]
        if type == "response.audio_transcript.done" {
            fields["type"] = .string("response.output_audio_transcript.done")
        } else {
            fields["type"] = .string(type)
        }
        for key in stringKeys {
            if case .string(let value) = event[key] {
                fields[key] = .string(value)
            }
        }
        for key in integerKeys {
            if case .number(let value) = event[key] {
                if value >= 0 && value.rounded() == value {
                    fields[key] = .number(value)
                }
            }
        }
        if type == "response.done" {
            let response = event["response"]
            let responseID = response["id"].stringValue
            if responseID.isEmpty == false {
                var safe: [String: JSONValue] = ["id": .string(responseID)]
                let status = response["status"].stringValue
                if ["completed", "cancelled", "failed", "incomplete"].contains(status) {
                    safe["status"] = .string(status)
                }
                if case .array(let items) = response["output"] {
                    var calls: [JSONValue] = []
                    for item in items {
                        if item["type"].stringValue != "function_call" {
                            continue
                        }
                        let callID = item["call_id"].stringValue
                        if callID.isEmpty {
                            continue
                        }
                        calls.append(.object([
                            "type": .string("function_call"),
                            "call_id": .string(callID)
                        ]))
                    }
                    safe["output"] = .array(calls)
                }
                fields["response"] = .object(safe)
            }
        }
        return .object(fields)
    }

    /// The provider is the voice agent, so its final transcript is the reply.
    static func transcriptUpdate(from event: JSONValue) -> GoblinVoiceTranscript? {
        let type = event["type"].stringValue
        if type == "conversation.item.input_audio_transcription.completed" {
            let text = event["transcript"].stringValue
            if text.isEmpty {
                return nil
            }
            return GoblinVoiceTranscript(role: "user", text: text)
        }
        if type == "response.output_audio_transcript.done" || type == "response.audio_transcript.done" {
            let text = event["transcript"].stringValue
            if text.isEmpty {
                return nil
            }
            return GoblinVoiceTranscript(role: "agent", text: text)
        }
        return nil
    }
}

// MARK: - App-owned playback accounting

struct GoblinPlaybackState: Equatable {
    private(set) var pendingBuffers = 0
    private(set) var seconds: Double = 0
    private(set) var generation = 0

    var isPlaying: Bool {
        pendingBuffers > 0
    }

    mutating func schedule(duration: Double) {
        pendingBuffers += 1
        seconds += duration
    }

    mutating func complete(duration: Double, generation: Int) {
        if generation != self.generation {
            return
        }
        pendingBuffers = max(0, pendingBuffers - 1)
        seconds = max(0, seconds - duration)
    }

    mutating func clear() {
        pendingBuffers = 0
        seconds = 0
        generation += 1
    }
}

// MARK: - Outbound frames

/// Ordered, bounded handoff from capture and control paths to the socket writer.
final class GoblinVoiceOutbox: @unchecked Sendable {
    struct Frame: Sendable {
        let text: String
        let byteCount: Int
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let maxBytes: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var closed = false

    init(maxBytes: Int = 1_048_576) {
        let pair = AsyncStream<Frame>.makeStream()
        self.frames = pair.stream
        self.continuation = pair.continuation
        self.maxBytes = maxBytes
    }

    /// False means the queue is over budget or already closed.
    func enqueue(_ frame: Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return false
        }
        if queuedBytes + frame.byteCount > maxBytes {
            return false
        }
        queuedBytes += frame.byteCount
        continuation.yield(frame)
        return true
    }

    func release(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        queuedBytes = max(0, queuedBytes - bytes)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return
        }
        closed = true
        continuation.finish()
    }
}

enum GoblinVoiceFrame {
    static func make(_ value: JSONValue) -> GoblinVoiceOutbox.Frame? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return GoblinVoiceOutbox.Frame(text: text, byteCount: data.count)
    }

    static func audio(_ pcm: Data) -> GoblinVoiceOutbox.Frame? {
        if pcm.isEmpty {
            return nil
        }
        return make(.object([
            "type": .string("input_audio_buffer.append"),
            "audio": .string(pcm.base64EncodedString())
        ]))
    }
}

// MARK: - Native audio

enum GoblinAudioError: Error, Equatable {
    case noInput
    case formatUnavailable
    case converterUnavailable
    case startFailed
}

extension GoblinAudioError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No microphone is available."
        case .formatUnavailable:
            return "The microphone audio format is unavailable."
        case .converterUnavailable:
            return "The microphone audio could not be converted to PCM16."
        case .startFailed:
            return "The audio engine could not start."
        }
    }
}

/// A copied capture buffer handed to the audio queue. The copy is owned by this
/// box alone after the tap returns, so crossing the queue is safe.
private final class GoblinCapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// One buffer for a single `AVAudioConverter.convert(to:error:withInputFrom:)` call.
/// That method invokes the input block on the calling thread and does not return
/// until the block has finished, so the flag and the buffer are not used by another thread.
private final class GoblinConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func pull(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

/// One AVAudioEngine for capture and playback, owned by the app.
/// Capture converts the live route format to mono 24 kHz PCM16 and frames it in 20 ms chunks.
final class GoblinAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.maverickkb.goblin.voice.audio")
    private let sampleRate: Double
    private let chunkFrames: Int
    private let maxPlaybackSeconds: TimeInterval
    private let maxPendingBuffers: Int
    private let captureSlots = DispatchSemaphore(value: 24)
    private let onFailure: @Sendable (String) -> Void
    private let speechMeter: SpeechMeter
    private var playerTapInstalled = false

    var onPlaybackIdle: (@Sendable () -> Void)?

    private var playerFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var carry = Data()
    private var muted = false
    private var running = false
    private var tapInstalled = false
    private var voiceProcessingEnabled = false
    private var playback = GoblinPlaybackState()
    private var onChunk: (@Sendable (Data) -> Bool)?

    init(
        sampleRate: Double,
        maxPlaybackSeconds: TimeInterval = 30,
        maxPendingBuffers: Int = 512,
        speechMeter: SpeechMeter = SpeechMeter(),
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.sampleRate = sampleRate
        self.chunkFrames = max(1, Int(sampleRate / 50))
        self.maxPlaybackSeconds = maxPlaybackSeconds
        self.maxPendingBuffers = maxPendingBuffers
        self.speechMeter = speechMeter
        self.onFailure = onFailure
    }

    var isPlayingBack: Bool {
        queue.sync { playback.isPlaying && running }
    }

    func start(onChunk: @escaping @Sendable (Data) -> Bool) throws {
        try queue.sync {
            if running {
                return
            }
            self.onChunk = onChunk

            engine.reset()
            if player.engine == nil {
                engine.attach(player)
            }
            guard let playFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw GoblinAudioError.formatUnavailable
            }
            playerFormat = playFormat
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)

            let input = engine.inputNode
            // Echo cancellation needs the playback graph as its reference, so it is
            // enabled before the route format is read.
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            } catch {
                voiceProcessingEnabled = false
                NSLog("Goblin voice: echo cancellation unavailable; capture is muted while the agent speaks.")
            }

            var routeFormat = input.outputFormat(forBus: 0)
            if routeFormat.sampleRate <= 0 || routeFormat.channelCount < 1 {
                try? input.setVoiceProcessingEnabled(false)
                voiceProcessingEnabled = false
                routeFormat = input.outputFormat(forBus: 0)
            }
            if routeFormat.sampleRate <= 0 || routeFormat.channelCount < 1 {
                throw GoblinAudioError.noInput
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw GoblinAudioError.formatUnavailable
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                teardownLocked()
                throw GoblinAudioError.startFailed
            }
            let latency = player.outputPresentationLatency
            let meter = speechMeter
            player.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, time in
                meter.record(buffer, at: time, latency: latency)
            }
            playerTapInstalled = true
            player.play()

            // Voice processing can change the live route format once the engine
            // runs. The tap and converter are built against that live format.
            let liveFormat = input.outputFormat(forBus: 0)
            if liveFormat.sampleRate <= 0 || liveFormat.channelCount < 1 {
                teardownLocked()
                throw GoblinAudioError.noInput
            }
            guard let builtConverter = AVAudioConverter(from: liveFormat, to: targetFormat) else {
                teardownLocked()
                throw GoblinAudioError.converterUnavailable
            }
            captureFormat = targetFormat
            converter = builtConverter

            let framesPerBuffer = AVAudioFrameCount(max(chunkFrames, Int(liveFormat.sampleRate / 50)))
            input.installTap(onBus: 0, bufferSize: framesPerBuffer, format: liveFormat) { [weak self] buffer, _ in
                self?.handleCaptureBuffer(buffer)
            }
            tapInstalled = true
            running = true
        }
    }

    /// Microphone-only mute. Playback keeps running.
    func setMuted(_ value: Bool) {
        queue.async {
            self.muted = value
            self.carry.removeAll(keepingCapacity: true)
        }
    }

    func enqueueBase64PCM16(_ encoded: String) {
        queue.async {
            do {
                let samples = try PCMCodec.pcm16LEBase64ToFloat(encoded)
                self.enqueueSamplesLocked(samples)
            } catch {
                self.failLocked("The provider sent audio that Goblin could not decode.")
            }
        }
    }

    /// Stop scheduled speech now. Late frames for the same response are dropped upstream.
    func clearPlayback() {
        queue.async {
            self.player.stop()
            if self.running {
                self.player.play()
            }
            self.playback.clear()
            self.speechMeter.clear()
            self.onPlaybackIdle?()
        }
    }

    func stop() {
        queue.sync {
            self.teardownLocked()
        }
    }

    private func teardownLocked() {
        running = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if playerTapInstalled {
            player.removeTap(onBus: 0)
            playerTapInstalled = false
        }
        player.stop()
        speechMeter.clear()
        if engine.isRunning {
            engine.stop()
        }
        if voiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
        }
        converter = nil
        captureFormat = nil
        playerFormat = nil
        carry.removeAll(keepingCapacity: false)
        playback.clear()
        onChunk = nil
        onPlaybackIdle = nil
    }

    private func handleCaptureBuffer(_ source: AVAudioPCMBuffer) {
        if captureSlots.wait(timeout: .now()) != .success {
            queue.async { self.failLocked("The microphone could not keep up. Voice stopped.") }
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            captureSlots.signal()
            return
        }
        copy.frameLength = source.frameLength
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        var index = 0
        while index < inputBuffers.count {
            if let inputData = inputBuffers[index].mData, let outputData = outputBuffers[index].mData {
                memcpy(outputData, inputData, Int(inputBuffers[index].mDataByteSize))
                outputBuffers[index].mDataByteSize = inputBuffers[index].mDataByteSize
            }
            index += 1
        }
        let captured = GoblinCapturedAudioBuffer(copy)
        queue.async {
            defer { self.captureSlots.signal() }
            if self.running == false {
                return
            }
            self.convertLocked(captured.buffer)
        }
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat = captureFormat else {
            return
        }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        let input = GoblinConverterInput(buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            input.pull(status)
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        if status == .error || conversionError != nil {
            failLocked("The microphone audio could not be converted.")
            return
        }
        if output.frameLength == 0 {
            return
        }
        guard let channel = output.int16ChannelData?[0] else {
            return
        }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        var payload = Data(bytes: channel, count: byteCount)
        // Zero the microphone while the agent is speaking. Barge-in is the
        // explicit interrupt, not live capture of the agent's own output.
        if muted || playback.isPlaying {
            payload = Data(count: payload.count)
        }
        appendLocked(payload)
    }

    private func appendLocked(_ payload: Data) {
        carry.append(payload)
        let bytesPerChunk = chunkFrames * MemoryLayout<Int16>.size
        while carry.count >= bytesPerChunk {
            let chunk = Data(carry.prefix(bytesPerChunk))
            carry.removeFirst(bytesPerChunk)
            guard let onChunk else {
                return
            }
            if onChunk(chunk) == false {
                failLocked("The voice send queue is full. Voice stopped.")
                return
            }
        }
    }

    private func enqueueSamplesLocked(_ samples: [Float]) {
        if running == false || samples.isEmpty {
            return
        }
        guard let format = playerFormat else {
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            failLocked("Voice playback ran out of audio buffers.")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            var index = 0
            while index < samples.count {
                channel[index] = samples[index]
                index += 1
            }
        }
        let duration = Double(samples.count) / sampleRate
        if playback.pendingBuffers >= maxPendingBuffers || playback.seconds + duration > maxPlaybackSeconds {
            failLocked("Voice playback fell behind and was stopped.")
            return
        }
        playback.schedule(duration: duration)
        let generation = playback.generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async {
                self.playback.complete(duration: duration, generation: generation)
                if self.playback.isPlaying == false {
                    self.onPlaybackIdle?()
                }
            }
        }
        if player.isPlaying == false {
            player.play()
        }
    }

    private func failLocked(_ message: String) {
        onFailure(message)
    }
}

// MARK: - Voice session

/// One explicit duplex voice call, bridged to the owning engine session.
///
/// Phase values: idle, starting, connecting, listening, speaking, muted, error.
/// The provider's speech is the agent's reply. Barge-in clears local playback,
/// and an explicit interrupt also discards the rest of that response.
@MainActor
@Observable
final class GoblinVoice: CompanionVoice {
    /// Persisted opt-in supplied by Settings. Each Start re-checks the real output.
    var allowSpeakers: Bool = false

    private(set) var phase: String = GoblinVoicePhase.idle.rawValue
    private(set) var isConnected = false
    private(set) var isMuted = false
    private(set) var isSpeaking = false
    private(set) var error = ""
    private(set) var outputDeviceName = ""
    @ObservationIgnored let speechMeter = SpeechMeter()

    var userIsSpeaking: Bool { userSpeaking }
    var characterSpeechLevel: Double { speechMeter.level() }
    /// Display-only caption. The engine owns authoritative history.
    private(set) var latestTranscript: GoblinVoiceTranscript?

    private let engine: EngineConnection
    private let connectTimeoutSeconds: TimeInterval = 20

    private var lease: GoblinVoiceLease?
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var outbox: GoblinVoiceOutbox?
    private var audio: GoblinAudioEngine?
    private var receiveTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var taskPollTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var bridgeChain: Task<Void, Never>?

    private var bridgePending = 0
    private(set) var isActive = false
    private var isEnding = false
    private var sentEventIDs: Set<String> = []
    private var suppressedResponseID: String?
    private var activeResponseID: String?
    private var utterance = 0
    private var responses: [String: Int] = [:]
    private var answered: Set<Int> = []
    private var answering = false
    private var responseAudioBytes = 0
    private var responseStartedAt: Date?
    private var userSpeaking = false
    private var taskPollNeeded = false
    private var taskPollRevision = 0
    private var runID = UUID()
    private var lastActivity = Date.distantPast

    init(engine: EngineConnection) {
        self.engine = engine
        self.outputDeviceName = GoblinAudioDevice.defaultOutput()?.name ?? ""
    }

    /// Fetch the lease, open the provider socket, and return once the session is accepted.
    func start(initiallyMuted: Bool = false) async throws {
        if isActive {
            return
        }
        if let endingTask {
            await endingTask.value
        }
        try Task.checkCancellation()
        if isActive { return }
        endingTask = nil
        runID = UUID()
        let run = runID
        isActive = true
        resetEventState()
        error = ""
        isMuted = initiallyMuted
        isSpeaking = false
        latestTranscript = nil
        phase = GoblinVoicePhase.starting.rawValue

        do {
            try await withTaskCancellationHandler {
                try await begin(run: run)
            } onCancel: {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.runID == run else { return }
                    self.beginFinish(.stopped)
                }
            }
        } catch is CancellationError {
            if runID == run { await stop() }
            throw CancellationError()
        } catch {
            if runID != run { throw CancellationError() }
            let thrown = error
            var message: String
            if thrown is CancellationError {
                message = "Voice start was cancelled."
            } else {
                message = (thrown as? LocalizedError)?.errorDescription ?? thrown.localizedDescription
            }
            if isEnding == false {
                self.error = message
                phase = GoblinVoicePhase.error.rawValue
                beginFinish(.failed(message))
                await endingTask?.value
            }
            throw GoblinVoiceError(message)
        }
    }

    /// End the call: socket, audio and the engine lease.
    func stop() async {
        if let endingTask {
            await endingTask.value
            return
        }
        if isActive == false {
            phase = GoblinVoicePhase.idle.rawValue
            isConnected = false
            return
        }
        beginFinish(.stopped)
        await endingTask?.value
    }

    /// Microphone-only mute. Playback and the socket stay up.
    func setMuted(_ muted: Bool) {
        if isActive == false {
            return
        }
        if isMuted == muted {
            return
        }
        isMuted = muted
        audio?.setMuted(muted)
        updatePhase()
    }

    /// Stop the agent's current speech. Session work is not cancelled here.
    func interrupt() async {
        if isActive == false {
            return
        }
        if let activeResponseID {
            suppressedResponseID = activeResponseID
            recoveryTask?.cancel()
            recoveryTask = nil
        }
        audio?.clearPlayback()
        updatePlaybackState()
    }

    // MARK: Start

    private func begin(run: UUID) async throws {
        guard current(run) else { throw CancellationError() }
        let output = GoblinAudioDevice.defaultOutput()
        if let output {
            outputDeviceName = output.name
            if output.usesBuiltInSpeakers && allowSpeakers == false {
                throw GoblinVoiceError(
                    "Voice is routed to built-in speakers (" + output.name + "). "
                    + "Connect headphones or another output, or enable Allow built-in speakers in Settings."
                )
            }
        } else {
            outputDeviceName = ""
        }

        let allowed = await requestMicrophoneAccess()
        guard current(run) else { throw CancellationError() }
        if allowed == false {
            throw GoblinVoiceError(
                "Microphone access is denied. Enable Goblin in System Settings > Privacy & Security > Microphone."
            )
        }

        let leaseValue: JSONValue
        do {
            leaseValue = try await engine.call("voice/start")
        } catch {
            throw GoblinVoiceError("The engine could not start voice. " + error.localizedDescription)
        }
        guard current(run) else {
            let lateID = GoblinVoiceLease.identifier(in: leaseValue)
            if lateID.isEmpty == false {
                _ = try? await engine.call("voice/stop", ["lease_id": .string(lateID)])
            }
            throw CancellationError()
        }

        let lease: GoblinVoiceLease
        do {
            lease = try GoblinVoiceLease(response: leaseValue)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let earlyID = GoblinVoiceLease.identifier(in: leaseValue)
            if earlyID.isEmpty == false {
                _ = try? await engine.call("voice/stop", ["lease_id": .string(earlyID)])
            }
            throw GoblinVoiceError(message)
        }
        self.lease = lease
        guard current(run) else {
            _ = try? await engine.call("voice/stop", ["lease_id": .string(lease.id)])
            self.lease = nil
            throw CancellationError()
        }
        connect(lease, run: run)
        try await waitForConnection(run: run)
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    private func current(_ run: UUID) -> Bool {
        return run == runID && isActive && !isEnding && !Task.isCancelled
    }

    private func noteActivity() {
        lastActivity = Date()
    }

    private func connect(_ lease: GoblinVoiceLease, run: UUID) {
        phase = GoblinVoicePhase.connecting.rawValue
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .responsiveAV
        let session = URLSession(configuration: configuration)
        urlSession = session

        let task = session.webSocketTask(with: lease.websocketURL, protocols: lease.protocols)
        socket = task
        let outbox = GoblinVoiceOutbox()
        self.outbox = outbox
        startWriter(outbox: outbox, socket: task, run: run)
        startReceiver(task: task, run: run)
        startPing(run: run)
        startWatchdog(run: run)
        task.resume()
        noteActivity()
        // The provider expects its accepted settings before any audio.
        send(lease.sessionUpdate)
        startDeadlineTimer(lease)
    }

    private func waitForConnection(run: UUID) async throws {
        var waited: TimeInterval = 0
        while true {
            if isConnected {
                return
            }
            if error.isEmpty == false {
                throw GoblinVoiceError(error)
            }
            if current(run) == false {
                throw CancellationError()
            }
            if waited >= connectTimeoutSeconds {
                throw GoblinVoiceError("Voice connection timed out.")
            }
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
    }

    // MARK: Socket

    private func startReceiver(task: URLSessionWebSocketTask, run: UUID) {
        receiveTask = Task { [weak self] in
            while true {
                guard let self else {
                    return
                }
                if Task.isCancelled {
                    return
                }
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    if Task.isCancelled || self.isEnding || self.current(run) == false {
                        return
                    }
                    self.fail("Voice disconnected. The provider connection closed.")
                    return
                }
                if Task.isCancelled || self.isEnding || self.current(run) == false {
                    return
                }
                switch message {
                case .string(let text):
                    self.handleSocketText(text, run: run)
                case .data:
                    self.fail("The voice provider sent a binary frame. Goblin voice expects JSON text.")
                    return
                @unknown default:
                    self.fail("The voice provider sent a frame Goblin cannot read.")
                    return
                }
            }
        }
    }

    private func startWriter(outbox: GoblinVoiceOutbox, socket: URLSessionWebSocketTask, run: UUID) {
        writerTask = Task { [weak self] in
            for await frame in outbox.frames {
                guard let self else {
                    return
                }
                if self.current(run) == false { return }
                do {
                    try await socket.send(.string(frame.text))
                    outbox.release(bytes: frame.byteCount)
                } catch {
                    if self.current(run) == false { return }
                    self.fail("Voice disconnected while sending audio. The provider connection closed.")
                    return
                }
            }
        }
    }

    private func startPing(run: UUID) {
        pingTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .seconds(20))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if Task.isCancelled || self.isEnding || self.current(run) == false {
                    return
                }
                do {
                    try await self.sendPing()
                    if self.current(run) == false { return }
                    self.noteActivity()
                } catch {
                    if self.current(run) == false {
                        return
                    }
                    self.fail("Voice connection stalled. The provider stopped answering.")
                    return
                }
            }
        }
    }

    private func sendPing() async throws {
        guard let socket else {
            throw GoblinVoiceError("The voice socket is closed.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startWatchdog(run: UUID) {
        watchdogTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if Task.isCancelled || self.current(run) == false {
                    return
                }
                if Date().timeIntervalSince(self.lastActivity) >= 45 {
                    self.fail("Voice connection stalled. The provider stopped answering.")
                    return
                }
            }
        }
    }

    private func startDeadlineTimer(_ lease: GoblinVoiceLease) {
        let seconds = lease.sessionExpiresAt.timeIntervalSinceNow
        if seconds <= 0 {
            fail("Voice session ended. The provider time limit was reached.")
            return
        }
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self else {
                return
            }
            if Task.isCancelled || self.isEnding {
                return
            }
            self.fail("Voice session ended. The provider time limit was reached.")
        }
    }

    private func handleSocketText(_ text: String, run: UUID) {
        if current(run) == false {
            return
        }
        noteActivity()
        if text.utf8.count > 262_144 {
            fail("The voice provider sent an oversized event.")
            return
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            fail("The voice provider sent an event Goblin could not read.")
            return
        }
        handleEvent(value, run: run)
    }

    private func handleEvent(_ event: JSONValue, run: UUID) {
        if current(run) == false {
            return
        }
        let type = event["type"].stringValue
        if type.isEmpty {
            fail("The voice provider sent an event without a type.")
            return
        }
        if type == "error" {
            fail("Voice provider error: " + providerErrorCode(event) + ".")
            return
        }
        if type == "session.updated" && isConnected == false {
            didConnect(run: run)
        }
        if isConnected == false {
            return
        }

        switch type {
        case "input_audio_buffer.speech_started":
            userSpeaking = true
            utterance += 1
            recoveryTask?.cancel()
            recoveryTask = nil
            if let activeResponseID {
                suppressedResponseID = activeResponseID
            }
            audio?.clearPlayback()
            updatePlaybackState()
        case "response.created":
            answering = true
            responseAudioBytes = 0
            responseStartedAt = Date()
            let responseID = event["response"]["id"].stringValue
            if responseID.isEmpty == false {
                responses[responseID] = utterance
                activeResponseID = responseID
            }
        case "response.output_audio.delta", "response.audio.delta":
            handleAudioDelta(event)
        case "response.done":
            answering = false
            let responseID = event["response"]["id"].stringValue
            if responseID.isEmpty == false {
                responses.removeValue(forKey: responseID)
                if activeResponseID == responseID {
                    activeResponseID = nil
                }
                if suppressedResponseID == responseID {
                    suppressedResponseID = nil
                }
            }
            updatePlaybackState()
        case "input_audio_buffer.speech_stopped":
            userSpeaking = false
            startRecoveryForCurrentUtterance()
        default:
            break
        }

        if let transcript = GoblinVoiceEventFilter.transcriptUpdate(from: event) {
            latestTranscript = transcript
        }
        if let bridged = GoblinVoiceEventFilter.bridgeEvent(from: event) {
            bridge(bridged)
        }
    }

    private func handleAudioDelta(_ event: JSONValue) {
        let responseID = event["response_id"].stringValue
        let owner = responses[responseID] ?? utterance
        let delta = event["delta"].stringValue
        if owner == utterance {
            responseAudioBytes += delta.utf8.count
            answered.insert(owner)
        }
        if suppressedResponseID != nil && responseID == suppressedResponseID {
            return
        }
        if delta.isEmpty {
            return
        }
        if let audio {
            audio.enqueueBase64PCM16(delta)
            isSpeaking = true
            updatePhase()
        }
    }

    private func didConnect(run: UUID) {
        if current(run) == false {
            return
        }
        guard let lease else {
            return
        }
        do {
            let outbox = self.outbox
            let audio = GoblinAudioEngine(sampleRate: lease.sampleRate, speechMeter: speechMeter) { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.current(run) else { return }
                    self.fail(message)
                }
            }
            audio.onPlaybackIdle = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.current(run) else { return }
                    self.updatePlaybackState()
                }
            }
            try audio.start { data in
                guard let outbox else {
                    return false
                }
                guard let frame = GoblinVoiceFrame.audio(data) else {
                    return false
                }
                return outbox.enqueue(frame)
            }
            audio.setMuted(isMuted)
            self.audio = audio
            isConnected = true
            updatePhase()
        } catch {
            fail("Microphone unavailable. " + error.localizedDescription)
        }
    }

    private func startRecoveryForCurrentUtterance() {
        recoveryTask?.cancel()
        let asked = utterance
        recoveryTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if Task.isCancelled || self.isActive == false || self.isConnected == false {
                    return
                }
                if asked != self.utterance {
                    return
                }
                if self.answered.contains(asked) {
                    return
                }
                if self.answering && self.responseAudioBytes == 0 {
                    let started = self.responseStartedAt ?? Date()
                    if Date().timeIntervalSince(started) < 8 {
                        continue
                    }
                }
                self.send(.object(["type": .string("response.create")]))
                return
            }
        }
    }

    private func providerErrorCode(_ event: JSONValue) -> String {
        let errorObject = event["error"]
        let type = errorObject["type"].stringValue
        if isSafeProviderCode(type) {
            return type
        }
        let code = errorObject["code"].stringValue
        if isSafeProviderCode(code) {
            return code
        }
        return "unknown"
    }

    private func isSafeProviderCode(_ value: String) -> Bool {
        if value.isEmpty || value.count > 64 {
            return false
        }
        for character in value {
            let allowed = character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-"
            if allowed == false {
                return false
            }
        }
        return true
    }

    // MARK: Bridge

    private func bridge(_ event: JSONValue) {
        bridgePending += 1
        if bridgePending > 32 {
            fail("Voice transcript sync stalled. Voice stopped.")
            return
        }
        let previous = bridgeChain
        let run = runID
        bridgeChain = Task { [weak self] in
            await previous?.value
            guard let self else {
                return
            }
            if self.current(run) == false { return }
            await self.sendBridgeEvent(event, run: run)
        }
    }

    private func sendBridgeEvent(_ event: JSONValue, run: UUID) async {
        defer {
            if runID == run { bridgePending = max(0, bridgePending - 1) }
        }
        guard current(run), let lease, isConnected else {
            return
        }
        do {
            let result = try await engine.call("voice/events", [
                "lease_id": .string(lease.id),
                "events": .array([event])
            ])
            if current(run) == false { return }
            switch result["send"] {
            case .array(let frames):
                for frame in frames {
                    send(frame)
                }
            case .null:
                break
            default:
                fail("The engine returned an invalid voice reply.")
                return
            }
            if result["poll_after_ms"] != .null {
                taskPollNeeded = true
                taskPollRevision += 1
                startTaskPollIfNeeded()
            }
        } catch {
            if current(run) == false { return }
            fail("Voice stopped. The engine could not record the voice event. " + error.localizedDescription)
        }
    }

    private var voiceIsIdle: Bool {
        userSpeaking == false && answering == false && bridgePending == 0 && isSpeaking == false
    }

    private func startTaskPollIfNeeded() {
        if taskPollTask != nil || taskPollNeeded == false {
            return
        }
        taskPollTask = Task { [weak self] in
            while true {
                guard let self else {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                if Task.isCancelled || self.isActive == false {
                    return
                }
                if self.voiceIsIdle == false {
                    continue
                }
                let revision = self.taskPollRevision
                let result: JSONValue
                do {
                    result = try await self.pollVoiceEvents()
                } catch {
                    if Task.isCancelled || self.isEnding {
                        return
                    }
                    self.fail("Task sync failed. The session result remains in chat.")
                    return
                }
                if Task.isCancelled || self.isActive == false {
                    return
                }
                // A completed task result arrives as conversation frames. Do not
                // talk over the user or the agent's current reply.
                while self.voiceIsIdle == false {
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    if self.isActive == false {
                        return
                    }
                }
                switch result["send"] {
                case .array(let frames):
                    for frame in frames {
                        self.send(frame)
                    }
                case .null:
                    break
                default:
                    self.fail("The engine returned an invalid task reply.")
                    return
                }
                if result["poll_after_ms"] != .null {
                    self.taskPollNeeded = true
                } else if revision == self.taskPollRevision {
                    self.taskPollNeeded = false
                }
                if self.taskPollNeeded == false {
                    self.taskPollTask = nil
                    return
                }
            }
        }
    }

    private func pollVoiceEvents() async throws -> JSONValue {
        guard let lease else {
            throw GoblinVoiceError("The voice lease is closed.")
        }
        return try await engine.call("voice/events", [
            "lease_id": .string(lease.id),
            "events": .array([])
        ])
    }

    // MARK: Sending

    private func send(_ value: JSONValue) {
        guard let outbox else {
            return
        }
        let eventID = value["event_id"].stringValue
        if eventID.isEmpty == false {
            if sentEventIDs.contains(eventID) {
                return
            }
            sentEventIDs.insert(eventID)
            if sentEventIDs.count > 4_096 {
                sentEventIDs.removeAll(keepingCapacity: true)
            }
        }
        guard let frame = GoblinVoiceFrame.make(value) else {
            fail("A voice frame could not be encoded.")
            return
        }
        if outbox.enqueue(frame) == false {
            fail("The voice send queue is full. Voice stopped.")
        }
    }

    // MARK: Phase

    private func updatePlaybackState() {
        if isActive == false {
            isSpeaking = false
            return
        }
        isSpeaking = audio?.isPlayingBack == true
        updatePhase()
    }

    private func updatePhase() {
        if isConnected == false {
            return
        }
        if isMuted {
            phase = GoblinVoicePhase.muted.rawValue
            return
        }
        if isSpeaking {
            phase = GoblinVoicePhase.speaking.rawValue
            return
        }
        phase = GoblinVoicePhase.listening.rawValue
    }

    // MARK: Finish

    private func beginFinish(_ ending: GoblinVoiceEnding) {
        if isEnding {
            return
        }
        runID = UUID()
        isEnding = true
        endingTask = Task { [weak self] in
            await self?.performFinish(ending)
        }
    }

    private func fail(_ message: String) {
        if isActive == false || isEnding {
            return
        }
        error = message
        phase = GoblinVoicePhase.error.rawValue
        beginFinish(.failed(message))
    }

    private func performFinish(_ ending: GoblinVoiceEnding) async {
        isActive = false
        isConnected = false

        receiveTask?.cancel()
        receiveTask = nil
        writerTask?.cancel()
        writerTask = nil
        pingTask?.cancel()
        pingTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        taskPollTask?.cancel()
        taskPollTask = nil
        bridgeChain?.cancel()
        bridgeChain = nil
        bridgePending = 0

        outbox?.close()
        outbox = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audio?.stop()
        audio = nil

        isSpeaking = false
        isMuted = false
        latestTranscript = nil
        suppressedResponseID = nil
        activeResponseID = nil
        userSpeaking = false
        answering = false

        let closingID = lease?.id ?? ""
        lease = nil

        switch ending {
        case .stopped:
            error = ""
            phase = GoblinVoicePhase.idle.rawValue
        case .failed(let message):
            error = message
            phase = GoblinVoicePhase.error.rawValue
        }

        if closingID.isEmpty == false {
            do {
                _ = try await engine.call("voice/stop", ["lease_id": .string(closingID)])
            } catch {
                if case .stopped = ending {
                    self.error = "Voice stopped locally. The engine did not confirm closing the voice lease."
                }
            }
        }
        isEnding = false
    }

    private func resetEventState() {
        lease = nil
        socket = nil
        urlSession = nil
        outbox = nil
        audio = nil
        receiveTask = nil
        writerTask = nil
        pingTask = nil
        deadlineTask = nil
        recoveryTask = nil
        taskPollTask = nil
        bridgeChain = nil
        bridgePending = 0
        sentEventIDs.removeAll(keepingCapacity: true)
        suppressedResponseID = nil
        activeResponseID = nil
        utterance = 0
        responses.removeAll(keepingCapacity: true)
        answered.removeAll(keepingCapacity: true)
        answering = false
        responseAudioBytes = 0
        responseStartedAt = nil
        userSpeaking = false
        taskPollNeeded = false
        taskPollRevision = 0
    }
}
