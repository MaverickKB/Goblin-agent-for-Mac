import Darwin
import Foundation

/// Private process pipes report a disconnected peer as an error, not a process signal.
enum PipeIO {
    static func write(_ data: Data, to handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: data)
    }

    /// The dedicated reader queue owns the blocking read, not a cooperative executor.
    static func read(_ handle: FileHandle, on queue: DispatchQueue) async -> Data {
        await withCheckedContinuation { continuation in
            queue.async {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }
}
