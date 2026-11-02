import Foundation
import XCTest
@testable import Goblin

/// Only ordinary system I/O programs are launched. No credential helper is invoked.
final class KeychainTransportTests: XCTestCase {
    func testExchangeDrainsAReplyLargerThanThePipeBuffer() throws {
        let value = String(repeating: "x", count: 40_000)
        let request = KeychainRequest(operation: "echo", service: "fixture.pipe", account: "test", value: value)
        let response = try KeychainBridge.exchange(request, executable: URL(fileURLWithPath: "/bin/cat"))
        XCTAssertEqual(response["value"], value)
        XCTAssertEqual(response["service"], "fixture.pipe")
    }

    func testHelperThatNeverFinishesIsTerminatedAtTheDeadline() {
        let request = KeychainRequest(operation: "echo", service: "fixture.pipe", account: "test", value: nil)
        do {
            _ = try KeychainBridge.exchange(request,
                                            executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                            timeout: .milliseconds(20))
            XCTFail("A nonterminating process must not produce a successful exchange.")
        } catch let error as GoblinError {
            XCTAssertEqual(error.message, "The credential helper did not answer in time.")
        } catch {
            XCTFail("Unexpected error: " + error.localizedDescription)
        }
    }

    func testExitedPeerProducesAnErrorInsteadOfKillingTheCaller() {
        let value = String(repeating: "x", count: 40_000)
        let request = KeychainRequest(operation: "echo", service: "fixture.pipe", account: "test", value: value)
        XCTAssertThrowsError(try KeychainBridge.exchange(request,
                                                        executable: URL(fileURLWithPath: "/usr/bin/true")))
    }
}

final class PipeIOTests: XCTestCase {
    func testClosedReadEndThrowsInsteadOfSendingSIGPIPE() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try PipeIO.write(Data("frame\n".utf8), to: pipe.fileHandleForWriting))
    }
}
