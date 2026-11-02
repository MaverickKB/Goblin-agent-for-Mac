import AppKit
import XCTest
@testable import Goblin

final class WindowPlacementTests: XCTestCase {
    private let left = NSRect(x: -1600, y: 24, width: 1600, height: 876)
    private let right = NSRect(x: 0, y: 24, width: 1440, height: 876)

    func testStraddlingWindowFitsTheDisplayContainingMostOfIt() {
        let frame = NSRect(x: -200, y: 100, width: 898, height: 674)
        let result = WindowPlacement.fitted(frame, screens: [left, right])
        XCTAssertTrue(right.contains(result))
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 100))
        XCTAssertEqual(result.size, frame.size)
    }

    func testDisconnectedDisplayPositionReturnsToTheNearestVisibleDisplay() {
        let frame = NSRect(x: 3000, y: -800, width: 898, height: 674)
        let result = WindowPlacement.fitted(frame, screens: [left, right])
        XCTAssertTrue(right.contains(result))
        XCTAssertEqual(result.origin, NSPoint(x: 542, y: 24))
    }

    func testValidNegativeScreenCoordinatesArePreserved() {
        let frame = NSRect(x: -1500, y: 100, width: 898, height: 674)
        XCTAssertEqual(WindowPlacement.fitted(frame, screens: [left, right]), frame)
    }

    func testShortDisplayKeepsTheHeaderReachableAndMissingDisplaysKeepTheFrame() {
        let frame = NSRect(x: 100, y: -900, width: 898, height: 1000)
        let result = WindowPlacement.fitted(frame, screens: [right])
        XCTAssertEqual(result.maxY, right.maxY)
        XCTAssertEqual(result.size, frame.size)
        XCTAssertEqual(WindowPlacement.fitted(frame, screens: []), frame)
    }
}
