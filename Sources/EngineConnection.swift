import Foundation
import Darwin
import Observation

struct PipeLineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) throws -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 10) {
            let bytes = data[..<newline]
            guard let line = String(data: bytes, encoding: .utf8) else {
                throw GoblinError(message: "Engine output is not UTF-8.")
            }
            lines.append(line)
            data.removeSubrange(...newline)
        }
        return lines
    }
}

enum EngineFrame: Sendable {
    case message(JSONValue)
    case invalid(String)
}

// Frames and decodes engine stdout on the reader queue. No MainActor work here.
struct EngineFrameDecoder {
    private var lines = PipeLineBuffer()
    private let decoder = JSONDecoder()

    mutating func append(_ chunk: Data) throws -> [EngineFrame] {
        let completeLines = try lines.append(chunk)
        var frames: [EngineFrame] = []
        for line in completeLines {
            do {
                let message = try decoder.decode(JSONValue.self, from: Data(line.utf8))
                frames.append(.message(message))
            } catch {
                frames.append(.invalid(error.localizedDescription))
            }
        }
        return frames
    }
}

// One token per child process. A late callback from an old reader may only
// act when its token still owns the connection.
struct EngineGeneration: Sendable {
    private(set) var current = 0

    mutating func beginNewProcess() -> Int {
        current += 1
        return current
    }

    func owns(_ generation: Int) -> Bool {
        return generation == current
    }
}

// Owns the child's stdin. Enqueue calls are synchronous on MainActor so the
// serial queue receives frames in call order, including Stop after intake.
@MainActor
final class EnginePipeWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
        self.queue = DispatchQueue(label: "engine.stdin." + UUID().uuidString)
    }

    func enqueue(_ frame: Data, onFailure: @escaping @Sendable (GoblinError) -> Void) -> Bool {
        if isClosed {
            return false
        }
        let handle = self.handle
        queue.async {
            do {
                try PipeIO.write(frame, to: handle)
            } catch {
                let failure = GoblinError(message: error.localizedDescription)
                onFailure(failure)
            }
        }
        return true
    }

    func close() {
        if isClosed {
            return
        }
        isClosed = true
        let handle = self.handle
        queue.async {
            try? handle.close()
        }
    }
}

@MainActor
@Observable
final class EngineConnection {
    private(set) var isRunning = false
    private(set) var diagnostic = ""
    var onEvent: ((String, JSONValue) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var processExited: DispatchSemaphore?
    @ObservationIgnored private var writer: EnginePipeWriter?
    @ObservationIgnored private var outputReader: Task<Void, Never>?
    @ObservationIgnored private var errorReader: Task<Void, Never>?
    @ObservationIgnored private var generation = EngineGeneration()
    @ObservationIgnored private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]

    func start(resources: URL, home: URL, applicationHome: URL? = nil) async throws {
        if process?.isRunning == true && isRunning { return }
        if let child = process, child.isRunning, let exited = processExited {
            let stopped = await Task.detached {
                Self.stopDisconnectedChild(child, exited: exited)
            }.value
            if !stopped { throw GoblinError(message: "The disconnected local engine could not be stopped.") }
        }
        if let previousReader = outputReader {
            await previousReader.value
        }
        try Task.checkCancellation()
        if process?.isRunning == true { return }
        let engine = resources.appendingPathComponent("Runtime")
        let python = engine.appendingPathComponent("Python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw GoblinError(message: "The bundled Python runtime is missing. Rebuild the app.")
        }
        outputReader?.cancel()
        errorReader?.cancel()
        outputReader = nil
        errorReader = nil
        close()

        diagnostic = ""
        let child = Process()
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = python
        child.arguments = ["-u", "-B", engine.appendingPathComponent("goblin_bridge.py").path,
                           "--home", home.path, "--manifest", resources.appendingPathComponent("product.json").path]
        if let applicationHome {
            child.arguments?.append(contentsOf: ["--application-home", applicationHome.path])
        }
        child.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["GOBLIN_HOME"] = home.path
        environment["GOBLIN_APPLICATION_HOME"] = (applicationHome ?? home).path
        environment["AETHERMIND_REGISTRY"] = home.appendingPathComponent("aethermind/project_registry.json").path
        environment["GOBLIN_RESOURCES"] = resources.path
        environment["GOBLIN_KEYCHAIN_HELPER"] = try KeychainBridge.helperURL(resources: resources).path
        environment["TMPDIR"] = home.appendingPathComponent("cache").path
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        try child.run()
        process = child
        processExited = exited
        writer = EnginePipeWriter(handle: stdin.fileHandleForWriting)
        isRunning = true
        let processGeneration = generation.beginNewProcess()
        outputReader = readOutput(stdout.fileHandleForReading, generation: processGeneration)
        errorReader = readErrors(stderr.fileHandleForReading, generation: processGeneration)
    }

    private nonisolated static func stopDisconnectedChild(_ child: Process, exited: DispatchSemaphore) -> Bool {
        if !child.isRunning { return true }
        child.terminate()
        if exited.wait(timeout: .now() + .seconds(2)) == .success { return true }
        if !child.isRunning { return true }
        kill(child.processIdentifier, SIGKILL)
        if exited.wait(timeout: .now() + .seconds(2)) == .success { return true }
        return !child.isRunning
    }

    // One blocking reader per stream. Keeping them separate means silent stderr
    // cannot delay stdout, and awaiting each publish preserves pipe order.
    private nonisolated func readOutput(_ handle: FileHandle, generation: Int) -> Task<Void, Never> {
        let queue = DispatchQueue(label: "engine.stdout", qos: .userInitiated)
        return Task.detached(priority: .userInitiated) { [weak self] in
            var decoder = EngineFrameDecoder()
            while !Task.isCancelled {
                let chunk = await PipeIO.read(handle, on: queue)
                if chunk.isEmpty {
                    await self?.engineEnded(generation: generation)
                    return
                }
                do {
                    let frames = try decoder.append(chunk)
                    await self?.publishOutput(frames, generation: generation)
                } catch {
                    decoder = EngineFrameDecoder()
                    await self?.publishFramingFailure(error.localizedDescription, generation: generation)
                }
            }
        }
    }

    private nonisolated func readErrors(_ handle: FileHandle, generation: Int) -> Task<Void, Never> {
        let queue = DispatchQueue(label: "engine.stderr", qos: .utility)
        return Task.detached(priority: .utility) { [weak self] in
            var lines = PipeLineBuffer()
            while !Task.isCancelled {
                let chunk = await PipeIO.read(handle, on: queue)
                if chunk.isEmpty {
                    return
                }
                do {
                    let completeLines = try lines.append(chunk)
                    await self?.publishDiagnostics(completeLines, generation: generation)
                } catch {
                    lines = PipeLineBuffer()
                    await self?.publishDiagnostics(["Engine diagnostics are not UTF-8."], generation: generation)
                }
            }
        }
    }

    @MainActor
    private func publishOutput(_ frames: [EngineFrame], generation: Int) {
        guard isRunning, self.generation.owns(generation) else { return }
        for frame in frames {
            switch frame {
            case .message(let message):
                receive(message)
            case .invalid(let reason):
                diagnostic = "Invalid engine frame: " + reason
            }
        }
    }

    @MainActor
    private func publishFramingFailure(_ reason: String, generation: Int) {
        guard isRunning, self.generation.owns(generation) else { return }
        diagnostic = "Invalid engine frame: " + reason
    }

    @MainActor
    private func publishDiagnostics(_ lines: [String], generation: Int) {
        guard isRunning, self.generation.owns(generation) else { return }
        for line in lines {
            diagnostic = String(line.suffix(4_000))
        }
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard isRunning, let writer else { throw GoblinError(message: "The local engine is not running.") }
        let processGeneration = generation.current
        let id = UUID().uuidString
        let request = JSONValue.object(["id": .string(id), "method": .string(method), "params": .object(params)])
        var data = try JSONEncoder().encode(request)
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            // Register the waiter before enqueueing so a fast response cannot
            // arrive before the pending entry exists.
            pending[id] = continuation
            let accepted = writer.enqueue(data) { [weak self] failure in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.generation.owns(processGeneration) else { return }
                    self.diagnostic = failure.localizedDescription
                    self.failPending(id: id, error: failure)
                    self.engineEnded(generation: processGeneration)
                }
            }
            if !accepted {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: GoblinError(message: "The local engine is not running."))
            }
        }
    }

    @MainActor
    private func failPending(id: String, error: GoblinError) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func receive(_ message: JSONValue) {
        let id = message["id"].stringValue
        if !id.isEmpty, let continuation = pending.removeValue(forKey: id) {
            if message["error"] != .null {
                continuation.resume(throwing: GoblinError(message: message["error"]["message"].stringValue))
            } else {
                continuation.resume(returning: message["result"])
            }
            return
        }
        let event = message["event"].stringValue
        if !event.isEmpty { onEvent?(event, message["data"]) }
    }

    @MainActor
    private func engineEnded(generation: Int) {
        guard self.generation.owns(generation) else { return }
        if !isRunning { return }
        isRunning = false
        outputReader?.cancel()
        errorReader?.cancel()
        outputReader = nil
        errorReader = nil
        close()
        let message = diagnostic.isEmpty ? "The local engine exited." : diagnostic
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: GoblinError(message: message))
        }
        onEvent?("disconnected", .string(message))
    }

    func close() {
        writer?.close()
        writer = nil
    }

    func shutdown() async {
        let processGeneration = generation.current
        let processWriter = writer
        let child = process
        let reader = outputReader
        if isRunning { _ = try? await call("shutdown") }
        processWriter?.close()
        if writer === processWriter {
            writer = nil
        }
        guard generation.owns(processGeneration), let child else { return }
        await Task.detached { child.waitUntilExit() }.value
        // Let the reader publish buffered responses and its EOF before pending
        // calls are failed, so a durable acknowledgment is not lost at quit.
        if let reader {
            await reader.value
        }
        guard generation.owns(processGeneration) else { return }
        process = nil
        engineEnded(generation: processGeneration)
    }

    func forceTerminate() {
        close()
        if let process, process.isRunning { process.terminate() }
    }
}
