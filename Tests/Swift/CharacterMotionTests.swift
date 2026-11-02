import Foundation
import XCTest
@testable import Goblin

final class CharacterMotionTests: XCTestCase {
    func testIdleHasSpacedHeadTurnsAndHandAdjustmentsWithoutSpeech() {
        var motion = CharacterMotion()
        var previous = CharacterPose()
        var blinks = 0
        var handMovementFrames = 0
        var quietHandFrames = 0
        var gazeRange = 0.0
        for _ in 0..<3600 {
            let pose = motion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(), enabled: true)
            if abs(pose.armAngle) + abs(pose.forearmAngle) > 0.01 {
                handMovementFrames += 1
            } else {
                quietHandFrames += 1
            }
            gazeRange = max(gazeRange, abs(pose.gazeX))
            XCTAssertEqual(pose.jaw, 0)
            XCTAssertLessThan(abs(pose.headAngle - previous.headAngle), 0.012)
            if pose.blink > 0.9 && previous.blink <= 0.9 { blinks += 1 }
            previous = pose
        }
        XCTAssertGreaterThan(handMovementFrames, 0)
        XCTAssertGreaterThan(quietHandFrames, handMovementFrames)
        XCTAssertGreaterThan(gazeRange, 0.1)
        XCTAssertGreaterThan(blinks, 4)
        XCTAssertLessThan(blinks, 12)
    }

    func testActivityEasesInAndSettlesWithoutPoseCut() {
        var motion = CharacterMotion()
        var maximumStep = 0.0
        var previous = 0.0
        var signals = CharacterSignals(working: true)
        for frame in 0..<300 {
            if frame == 120 { signals.working = false }
            let pose = motion.advance(seconds: 1.0 / 60.0, signals: signals, enabled: true)
            maximumStep = max(maximumStep, abs(pose.armAngle - previous))
            previous = pose.armAngle
        }
        XCTAssertLessThan(maximumStep, 0.012)
        XCTAssertLessThan(abs(previous), 0.0003)
    }

    func testSilenceDoesNotMoveTheMouthEvenDuringAVoiceResponse() {
        var motion = CharacterMotion()
        let signals = CharacterSignals(speaking: true, speechLevel: 0)
        for _ in 0..<120 {
            let pose = motion.advance(seconds: 1.0 / 60.0, signals: signals, enabled: true)
            XCTAssertEqual(pose.jaw, 0)
            XCTAssertEqual(pose.armAngle, 0)
        }
    }

    func testSpeechTracksThePlaybackEnvelopeAndClosesAfterStop() {
        var motion = CharacterMotion()
        var pose = CharacterPose()
        for _ in 0..<30 {
            pose = motion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(speaking: true, speechLevel: 0.7), enabled: true)
        }
        XCTAssertGreaterThan(pose.jaw, 0.65)
        for _ in 0..<30 {
            pose = motion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(), enabled: true)
        }
        XCTAssertLessThan(pose.jaw, 0.001)
    }

    func testReduceMotionIsTheOriginalRestGeometry() {
        var motion = CharacterMotion()
        let pose = motion.advance(seconds: 1, signals: CharacterSignals(working: true, speaking: true, speechLevel: 1), enabled: false)
        XCTAssertEqual(pose.breath, 0)
        XCTAssertEqual(pose.headAngle, 0)
        XCTAssertEqual(pose.headX, 0)
        XCTAssertEqual(pose.armAngle, 0)
        XCTAssertEqual(pose.blink, 0)
        XCTAssertEqual(pose.jaw, 0)
    }

    func testEveryBundledRigHasPlantedFeetAndNoFoldedTriangles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/character-rigs.json"))
        let catalog = try JSONDecoder().decode(CharacterRigCatalog.self, from: data)
        let avatarsData = try Data(contentsOf: root.appendingPathComponent("Resources/avatars.json"))
        let avatars = try JSONDecoder().decode([Avatar].self, from: avatarsData)
        XCTAssertEqual(catalog.avatars.count, avatars.count)
        for avatar in avatars {
            let rig = try XCTUnwrap(catalog.avatars[avatar.id])
            XCTAssertTrue(rig.isValid, avatar.id)
            let mesh = CharacterMesh(rig: rig, aspect: 0.56)
            var pose = CharacterPose()
            pose.breath = 1
            pose.headAngle = 0.14
            pose.headX = 0.015
            pose.headY = -0.007
            pose.bodyX = 0.009
            pose.bodyAngle = 0.045
            pose.armAngle = 0.16
            pose.forearmAngle = 0.17
            pose.arm2Angle = 0.16
            pose.forearm2Angle = 0.17
            pose.jaw = 1
            let moved = mesh.destinations(for: pose)
            var movedSecondArmVertices = 0
            for index in mesh.vertices.indices {
                let vertex = mesh.vertices[index]
                if vertex.arm2Weight > 0.4 {
                    let source = mesh.source[index]
                    let differenceX = moved[index].x - source.x
                    let differenceY = moved[index].y - source.y
                    if abs(differenceX) > 0.0001 || abs(differenceY) > 0.0001 {
                        movedSecondArmVertices += 1
                    }
                }
            }
            XCTAssertGreaterThan(movedSecondArmVertices, 0, avatar.id)
            for index in mesh.source.indices {
                let source = mesh.source[index]
                if source.y < 0.12 {
                    XCTAssertEqual(moved[index].x, source.x, accuracy: 0.00001, avatar.id)
                    XCTAssertEqual(moved[index].y, source.y, accuracy: 0.00001, avatar.id)
                }
            }
            for row in 0..<CharacterMesh.rows {
                for column in 0..<CharacterMesh.columns {
                    let index = row * (CharacterMesh.columns + 1) + column
                    let a = moved[index]
                    let b = moved[index + 1]
                    let c = moved[index + CharacterMesh.columns + 1]
                    let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                    XCTAssertGreaterThan(cross, 0, avatar.id)
                }
            }
        }
    }

    func testReactiveSignalsShapeThePose() {
        var errorMotion = CharacterMotion()
        var errorPose = CharacterPose()
        for _ in 0..<30 {
            errorPose = errorMotion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(error: true), enabled: true)
        }
        XCTAssertLessThan(errorPose.bodyY, 0)
        XCTAssertLessThan(errorPose.smile, 0)

        var approvalMotion = CharacterMotion()
        var approvalPose = CharacterPose()
        for _ in 0..<30 {
            approvalPose = approvalMotion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(approval: true), enabled: true)
        }
        XCTAssertGreaterThan(approvalPose.armAngle, 0.02)

        var typingMotion = CharacterMotion()
        var typingPose = CharacterPose()
        for _ in 0..<30 {
            typingPose = typingMotion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(typing: true), enabled: true)
        }
        XCTAssertLessThan(typingPose.gazeX, -0.05)

        var autonomyMotion = CharacterMotion()
        var autonomyPose = CharacterPose()
        for _ in 0..<60 {
            autonomyPose = autonomyMotion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(autonomy: true), enabled: true)
        }
        XCTAssertGreaterThan(abs(autonomyPose.headAngle), 0.01)

        var completionMotion = CharacterMotion()
        var completionPose = CharacterPose()
        for _ in 0..<30 {
            completionPose = completionMotion.advance(seconds: 1.0 / 60.0, signals: CharacterSignals(completed: true), enabled: true)
        }
        XCTAssertLessThan(completionPose.headY, 0)
        XCTAssertGreaterThan(completionPose.smile, 0.1)
    }

    func testToolActivityAddsAGestureToTheWorkingArm() {
        var motion = CharacterMotion()
        var maximumArm = 0.0
        var signals = CharacterSignals()
        for _ in 0..<60 {
            let pose = motion.advance(seconds: 1.0 / 60.0, signals: signals, enabled: true)
            maximumArm = max(maximumArm, abs(pose.armAngle))
        }
        signals.working = true
        signals.toolKind = "shell"
        signals.activityToken = 1
        for _ in 0..<30 {
            let pose = motion.advance(seconds: 1.0 / 60.0, signals: signals, enabled: true)
            maximumArm = max(maximumArm, abs(pose.armAngle))
        }
        XCTAssertGreaterThan(maximumArm, 0.12)
    }
}
