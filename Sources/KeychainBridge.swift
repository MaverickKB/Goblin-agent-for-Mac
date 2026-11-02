import Darwin
import Foundation
import Synchronization

struct KeychainRequest: Codable, Sendable {
    let operation: String
    let service: String
    let account: String
    let value: String?
}

enum KeychainBridge {
    /// One helper process runs at a time, and never on the UI thread.
    private static let lane = DispatchQueue(label: "credentials.lane",
                                            qos: .userInitiated)

    /// How long a terminated helper may take to exit before it is killed.
    private static let terminationGrace: DispatchTimeInterval = .seconds(2)
    static func helperURL(resources: URL) throws -> URL {
        let data = try Data(contentsOf: resources.appendingPathComponent("product.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let helpers = object?["native_helpers"] as? [String: Any]
        let definition = helpers?["keychain"] as? [String: Any]
        guard let name = definition?["name"] as? String, !name.isEmpty else {
            throw GoblinError(message: "The credential helper is not configured.")
        }
        return resources.appendingPathComponent("Helpers/" + name + ".app/Contents/MacOS/" + name)
    }

    static func request(_ request: KeychainRequest) async throws -> [String: String] {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: String], Error>) in
                lane.async {
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let resources = try GoblinMain.locateResources()
                        let executable = try helperURL(resources: resources)
                        let answer = try exchange(request, executable: executable)
                        continuation.resume(returning: answer)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    static func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lane.async { continuation.resume() }
        }
    }

    /// Reading and writing run concurrently so either payload can exceed pipe capacity.
    static func exchange(_ request: KeychainRequest, executable: URL,
                         timeout: DispatchTimeInterval = .seconds(10)) throws -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GoblinError(message: "The bundled credential helper is missing.")
        }
        let requestData = try JSONEncoder().encode(request)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        let pipeWork = DispatchGroup()
        let reply = Mutex((data: Data(), readError: false, writeError: false))
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let expires = DispatchTime.now() + timeout
        let inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading

        pipeWork.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? outputHandle.close()
                pipeWork.leave()
            }
            do {
                let data = try outputHandle.readToEnd() ?? Data()
                reply.withLock { $0.data = data }
            } catch {
                reply.withLock { $0.readError = true }
            }
        }
        pipeWork.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? inputHandle.close()
                pipeWork.leave()
            }
            do {
                try PipeIO.write(requestData, to: inputHandle)
            } catch {
                reply.withLock { $0.writeError = true }
            }
        }

        if exited.wait(timeout: expires) == .timedOut {
            let stopped = stopHelper(process, exited: exited)
            if !stopped {
                throw GoblinError(message: "The credential helper did not stop after the deadline.")
            }
            throw GoblinError(message: "The credential helper did not answer in time.")
        }

        guard pipeWork.wait(timeout: expires) == .success else {
            throw GoblinError(message: "The credential helper did not return a complete answer in time.")
        }
        let result = reply.withLock { $0 }
        guard !result.writeError else {
            throw GoblinError(message: "The credential helper could not receive the request.")
        }
        guard !result.readError else {
            throw GoblinError(message: "The credential helper answer could not be read.")
        }
        let data = result.data
        guard process.terminationStatus == 0 else {
            throw GoblinError(message: "The credential helper could not complete the request.")
        }
        let response = try JSONDecoder().decode([String: String].self, from: data)
        if response["state"] == "error" {
            throw GoblinError(message: response["message"] ?? "Credential access is unavailable.")
        }
        return response
    }

    /// Terminates the exact helper process this call started, then kills it if it
    /// ignores termination. Returns true once that child has exited.
    private static func stopHelper(_ process: Process, exited: DispatchSemaphore) -> Bool {
        if process.isRunning {
            process.terminate()
        }
        if exited.wait(timeout: .now() + terminationGrace) == .success {
            return true
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        return exited.wait(timeout: .now() + terminationGrace) == .success
    }
}
