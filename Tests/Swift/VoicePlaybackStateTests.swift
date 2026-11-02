import XCTest
@testable import Goblin

final class VoicePlaybackStateTests: XCTestCase {
    func testTracksQueuedSpeech() {
        var state = GoblinPlaybackState()
        XCTAssertFalse(state.isPlaying)
        state.schedule(duration: 0.5)
        state.schedule(duration: 0.25)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.pendingBuffers, 2)
        XCTAssertEqual(state.seconds, 0.75, accuracy: 0.0001)

        let generation = state.generation
        state.complete(duration: 0.5, generation: generation)
        XCTAssertEqual(state.pendingBuffers, 1)
        XCTAssertEqual(state.seconds, 0.25, accuracy: 0.0001)
        XCTAssertTrue(state.isPlaying)
    }

    func testClearStopsPlaybackAndInvalidatesLateCompletions() {
        var state = GoblinPlaybackState()
        state.schedule(duration: 1.0)
        let oldGeneration = state.generation
        state.clear()
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.pendingBuffers, 0)
        XCTAssertEqual(state.seconds, 0, accuracy: 0.0001)

        state.complete(duration: 1.0, generation: oldGeneration)
        XCTAssertEqual(state.pendingBuffers, 0, "A completion from before the clear must be ignored")
        XCTAssertEqual(state.seconds, 0, accuracy: 0.0001)
    }

    func testCountsNeverGoNegative() {
        var state = GoblinPlaybackState()
        state.schedule(duration: 0.1)
        let generation = state.generation
        state.complete(duration: 0.1, generation: generation)
        state.complete(duration: 0.1, generation: generation)
        XCTAssertEqual(state.pendingBuffers, 0)
        XCTAssertEqual(state.seconds, 0, accuracy: 0.0001)
    }
}
