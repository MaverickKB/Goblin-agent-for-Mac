import Foundation

struct CharacterSignals: Equatable {
    var listening = false
    var thinking = false
    var working = false
    var speaking = false
    var attention = false
    var speechLevel = 0.0
    var error = false
    var approval = false
    var autonomy = false
    var typing = false
    var toolKind = ""
    var activityToken = 0
    var completed = false
}

struct MotionSpring {
    var value = 0.0
    var velocity = 0.0

    mutating func advance(to target: Double, seconds: Double, response: Double) {
        let omega = 2.0 / response
        let offset = value - target
        let decay = exp(-omega * seconds)
        let change = (velocity + omega * offset) * seconds
        value = target + (offset + change) * decay
        velocity = (velocity - omega * change) * decay
    }
}

struct CharacterPose {
    var breath = 0.0
    var bodyX = 0.0
    var bodyY = 0.0
    var bodyAngle = 0.0
    var headAngle = 0.0
    var headX = 0.0
    var headY = 0.0
    var armAngle = 0.0
    var forearmAngle = 0.0
    var arm2Angle = 0.0
    var forearm2Angle = 0.0
    var blink = 0.0
    var gazeX = 0.0
    var gazeY = 0.0
    var jaw = 0.0
    var smile = 0.0
    var brow = 0.0
}

struct CharacterMotion {
    private var elapsed = 0.0
    private var listening = MotionSpring()
    private var thinking = MotionSpring()
    private var working = MotionSpring()
    private var speaking = MotionSpring()
    private var attention = MotionSpring()
    private var concern = MotionSpring()
    private var approval = MotionSpring()
    private var autonomy = MotionSpring()
    private var typing = MotionSpring()
    private var smile = MotionSpring()
    private var brow = MotionSpring()
    private var squint = MotionSpring()
    private var jaw = MotionSpring()
    private var blinkStart = 5.3
    private var blinkIndex = 0
    private let blinkGaps = [6.7, 4.9, 8.2, 5.8, 7.4]
    private var gestureStart = -10.0
    private var nextGesture = 2.4
    private var gestureIndex = 0
    private var gestureKind = 0
    private let gestureGaps = [6.1, 8.7, 7.3, 10.2, 6.8]
    private var toolGestureStart = -10.0
    private var toolGestureKind = ""
    private var lastActivityToken = 0
    private var completionStart = -10.0

    mutating func advance(seconds: Double, signals: CharacterSignals, enabled: Bool) -> CharacterPose {
        let step = max(0, min(seconds, 1.0 / 15.0))
        elapsed += step
        if !enabled { return CharacterPose() }

        advanceSprings(signals: signals, step: step)

        let speech = signals.speaking ? max(0, min(signals.speechLevel, 1)) : 0
        jaw.advance(to: speech, seconds: step, response: 0.075)

        let breathing = sin(elapsed * 2 * .pi / 4.8)
        let secondary = sin(elapsed * 2 * .pi / 7.1)
        let workPhase = elapsed * 2 * .pi / 1.65
        let workBeat = sin(workPhase)
        let thoughtBeat = sin(elapsed * 2 * .pi / 5.6)
        let utterance = speaking.value * jaw.value
        let engagement = maxEngagement()
        let idleWeight = max(0, 1 - engagement)
        let idlePose = idleGesture()
        let toolPose = toolGesturePose(for: signals)
        let completionPose = completionGesturePose(for: signals)

        var pose = CharacterPose()
        pose.breath = breathing
        pose.bodyX = 0.003 * working.value * workBeat
        pose.bodyAngle = 0.008 * working.value * sin(workPhase * 0.5)
        pose.headAngle = 0.002 * secondary
        pose.headAngle += 0.055 * listening.value
        pose.headAngle -= 0.04 * thinking.value
        pose.headAngle += 0.055 * thinking.value * thoughtBeat
        pose.headAngle += 0.014 * working.value * workBeat
        pose.headAngle += 0.018 * utterance
        pose.headX = 0.004 * attention.value
        pose.headX += 0.008 * thinking.value * thoughtBeat
        pose.headY = -0.0015 * breathing
        pose.headY += 0.003 * listening.value
        pose.headY -= 0.008 * thinking.value
        pose.headY += working.value * (-0.006 + 0.003 * workBeat)
        pose.armAngle = working.value * (0.085 + 0.065 * workBeat)
        pose.armAngle += 0.045 * thinking.value * (1 + thoughtBeat)
        pose.armAngle += 0.065 * utterance
        pose.forearmAngle = working.value * (0.09 + 0.075 * sin(workPhase + 1.1))
        pose.forearmAngle += 0.06 * thinking.value * (1 - thoughtBeat)
        pose.forearmAngle += 0.09 * utterance
        pose.gazeX = 0.4 * attention.value
        pose.gazeX += 0.28 * thinking.value * thoughtBeat
        pose.gazeX += 0.24 * working.value
        pose.gazeY = 0.18 * thinking.value
        pose.gazeY -= 0.12 * listening.value
        pose.gazeY += 0.14 * working.value
        pose.jaw = jaw.value

        pose.armAngle += 0.08 * thinking.value * (0.6 + 0.4 * thoughtBeat)
        pose.forearmAngle += 0.1 * thinking.value * (0.5 + 0.5 * thoughtBeat)
        pose.headAngle += 0.04 * thinking.value
        pose.gazeY += 0.2 * thinking.value
        pose.bodyAngle += 0.01 * working.value
        pose.gazeY += 0.1 * working.value
        pose.armAngle += 0.05 * utterance * (0.5 + 0.5 * sin(elapsed * 2 * .pi / 1.9))
        pose.forearmAngle += 0.07 * utterance
        pose.headAngle += 0.02 * utterance
        pose.headAngle += 0.06 * listening.value
        pose.headX += 0.01 * listening.value
        pose.bodyX += 0.006 * listening.value
        pose.gazeX += 0.3 * listening.value
        pose.gazeX += 0.3 * attention.value
        pose.headX += 0.008 * attention.value
        pose.bodyY -= 0.006 * concern.value
        pose.headAngle -= 0.05 * concern.value
        pose.headY -= 0.004 * concern.value
        pose.armAngle -= 0.03 * concern.value
        pose.forearmAngle -= 0.02 * concern.value
        pose.headAngle += 0.015 * concern.value * sin(elapsed * 2 * .pi / 1.6)
        pose.bodyX += 0.006 * approval.value
        pose.headAngle += 0.04 * approval.value
        pose.armAngle += 0.08 * approval.value
        pose.forearmAngle += 0.1 * approval.value
        pose.gazeX += 0.3 * approval.value
        pose.headAngle += 0.06 * autonomy.value * sin(elapsed * 2 * .pi / 6.2)
        pose.gazeX += 0.35 * autonomy.value * sin(elapsed * 2 * .pi / 5.0)
        pose.bodyAngle += 0.02 * autonomy.value * sin(elapsed * 2 * .pi / 7.0)
        pose.armAngle += 0.04 * autonomy.value
        pose.bodyX += 0.005 * typing.value
        pose.headAngle -= 0.02 * typing.value
        pose.gazeX -= 0.25 * typing.value
        pose.gazeY += 0.12 * typing.value
        pose.arm2Angle += 0.03 * thinking.value * (0.6 + 0.4 * thoughtBeat)
        pose.forearm2Angle += 0.04 * thinking.value * (0.5 + 0.5 * thoughtBeat)
        pose.arm2Angle += 0.02 * working.value * workBeat
        pose.forearm2Angle += 0.03 * working.value * sin(workPhase + 1.1)
        pose.arm2Angle += 0.04 * utterance * (0.5 + 0.5 * sin(elapsed * 2 * .pi / 1.9 + 1.2))
        pose.forearm2Angle += 0.06 * utterance
        pose.arm2Angle -= 0.03 * concern.value
        pose.forearm2Angle -= 0.02 * concern.value
        pose.arm2Angle += 0.04 * approval.value
        pose.forearm2Angle += 0.06 * approval.value
        pose.arm2Angle += 0.03 * autonomy.value * sin(elapsed * 2 * .pi / 6.2 + 0.8)

        addPose(&pose, idlePose, scale: idleWeight)
        addPose(&pose, toolPose, scale: 1)
        addPose(&pose, completionPose, scale: 1)
        pose.smile = smile.value
        pose.brow = brow.value
        pose.blink = max(blinkAmount(), squint.value * 0.35)
        return pose
    }

    private mutating func advanceSprings(signals: CharacterSignals, step: Double) {
        listening.advance(to: signals.listening ? 1 : 0, seconds: step, response: 0.34)
        thinking.advance(to: signals.thinking ? 1 : 0, seconds: step, response: 0.65)
        working.advance(to: signals.working ? 1 : 0, seconds: step, response: 0.55)
        speaking.advance(to: signals.speaking ? 1 : 0, seconds: step, response: 0.4)
        attention.advance(to: signals.attention ? 1 : 0, seconds: step, response: 0.45)
        concern.advance(to: signals.error ? 1 : 0, seconds: step, response: 0.5)
        approval.advance(to: signals.approval ? 1 : 0, seconds: step, response: 0.4)
        autonomy.advance(to: signals.autonomy ? 1 : 0, seconds: step, response: 0.6)
        typing.advance(to: signals.typing ? 1 : 0, seconds: step, response: 0.3)
        smile.advance(to: smileTarget(for: signals), seconds: step, response: 0.4)
        brow.advance(to: browTarget(for: signals), seconds: step, response: 0.35)
        let squintTarget = (signals.thinking || signals.error) ? 0.5 : 0
        squint.advance(to: squintTarget, seconds: step, response: 0.3)
    }

    private func maxEngagement() -> Double {
        var result = listening.value
        result = max(result, thinking.value)
        result = max(result, working.value)
        result = max(result, speaking.value)
        result = max(result, concern.value)
        result = max(result, approval.value)
        result = max(result, autonomy.value)
        result = max(result, typing.value)
        return result
    }

    private func smileTarget(for signals: CharacterSignals) -> Double {
        if signals.error { return -0.3 }
        if signals.completed { return 0.4 }
        if signals.speaking { return 0.25 }
        if signals.listening { return 0.2 }
        if signals.approval { return 0.1 }
        if signals.working { return 0.1 }
        if signals.thinking { return 0.05 }
        return 0.12
    }

    private func browTarget(for signals: CharacterSignals) -> Double {
        if signals.error { return -0.2 }
        if signals.approval { return 0.3 }
        if signals.thinking { return 0.2 }
        if signals.completed { return 0.2 }
        return 0.0
    }

    private mutating func idleGesture() -> CharacterPose {
        let duration = 3.2
        if elapsed >= nextGesture {
            gestureStart = elapsed
            gestureKind = gestureIndex % 8
            nextGesture = elapsed + duration + gestureGaps[gestureIndex % gestureGaps.count]
            gestureIndex += 1
        }
        let progress = (elapsed - gestureStart) / duration
        var pose = CharacterPose()
        if progress < 0 || progress > 1 { return pose }
        let envelope = pow(sin(progress * .pi), 2)
        let turn = sin(progress * 2 * .pi) * envelope
        switch gestureKind {
        case 0:
            pose.headAngle = 0.16 * turn
            pose.headX = 0.014 * turn
            pose.gazeX = 0.65 * turn
            pose.bodyX = 0.007 * turn
        case 1:
            pose.armAngle = 0.14 * envelope
            pose.forearmAngle = -0.08 * envelope
            pose.headAngle = -0.055 * envelope
            pose.bodyX = 0.008 * envelope
        case 2:
            pose.bodyAngle = 0.045 * turn
            pose.bodyX = 0.009 * turn
            pose.headAngle = -0.075 * turn
            pose.gazeX = -0.35 * turn
        case 3:
            pose.armAngle = 0.16 * envelope
            pose.forearmAngle = -0.1 * envelope
            pose.arm2Angle = 0.16 * envelope
            pose.forearm2Angle = -0.1 * envelope
            pose.bodyY = 0.004 * envelope
            pose.headAngle = -0.04 * envelope
        case 4:
            pose.armAngle = 0.12 * envelope
            pose.forearmAngle = 0.1 * envelope
            pose.headAngle = 0.04 * envelope
            pose.gazeY = -0.1 * envelope
            pose.gazeX = 0.2 * envelope
        case 5:
            pose.armAngle = 0.18 * envelope
            pose.forearmAngle = 0.12 * envelope
            pose.headAngle = -0.03 * envelope
            pose.gazeY = 0.1 * envelope
        case 6:
            pose.bodyY = 0.003 * envelope * sin(progress * 2 * .pi * 3)
            pose.bodyAngle = 0.02 * envelope
            pose.headAngle = 0.02 * envelope
        default:
            pose.armAngle = 0.1 * envelope
            pose.forearmAngle = 0.12 * envelope
            pose.arm2Angle = 0.1 * envelope
            pose.forearm2Angle = 0.12 * envelope
            pose.bodyAngle = -0.02 * envelope
        }
        return pose
    }

    private mutating func toolGesturePose(for signals: CharacterSignals) -> CharacterPose {
        if signals.activityToken != lastActivityToken {
            lastActivityToken = signals.activityToken
            toolGestureStart = elapsed
            toolGestureKind = signals.toolKind
        }
        let duration = 0.8
        let progress = (elapsed - toolGestureStart) / duration
        if progress < 0 || progress > 1 { return CharacterPose() }
        let envelope = pow(sin(progress * .pi), 2)
        var pose = CharacterPose()
        switch toolGestureKind {
        case "shell":
            pose.armAngle = 0.16 * envelope * sin(progress * 2 * .pi * 2)
            pose.forearmAngle = 0.18 * envelope * sin(progress * 2 * .pi * 2 + 0.6)
            pose.bodyAngle = 0.015 * envelope
        case "read_file", "read":
            pose.forearmAngle = 0.1 * envelope * sin(progress * .pi)
            pose.headAngle = 0.03 * envelope
            pose.gazeY = 0.1 * envelope
        case "write_file", "write":
            pose.forearmAngle = 0.08 * envelope * sin(progress * 2 * .pi * 3)
            pose.headAngle = 0.02 * envelope
        case "browser", "search", "web_search":
            pose.headAngle = 0.05 * envelope * sin(progress * 2 * .pi)
            pose.gazeX = 0.3 * envelope
        default:
            pose.armAngle = 0.06 * envelope
            pose.forearmAngle = 0.08 * envelope
        }
        return pose
    }

    private mutating func completionGesturePose(for signals: CharacterSignals) -> CharacterPose {
        if signals.completed && completionStart < 0 {
            completionStart = elapsed
        }
        if !signals.completed {
            completionStart = -10.0
            return CharacterPose()
        }
        let duration = 1.2
        let progress = (elapsed - completionStart) / duration
        if progress < 0 || progress > 1 { return CharacterPose() }
        let envelope = pow(sin(progress * .pi), 2)
        var pose = CharacterPose()
        pose.headY = -0.006 * envelope
        pose.headAngle = 0.03 * envelope
        pose.bodyY = 0.002 * envelope
        pose.smile = 0.15 * envelope
        return pose
    }

    private func addPose(_ target: inout CharacterPose, _ addition: CharacterPose, scale: Double) {
        target.bodyX += addition.bodyX * scale
        target.bodyY += addition.bodyY * scale
        target.bodyAngle += addition.bodyAngle * scale
        target.headAngle += addition.headAngle * scale
        target.headX += addition.headX * scale
        target.headY += addition.headY * scale
        target.armAngle += addition.armAngle * scale
        target.forearmAngle += addition.forearmAngle * scale
        target.arm2Angle += addition.arm2Angle * scale
        target.forearm2Angle += addition.forearm2Angle * scale
        target.gazeX += addition.gazeX * scale
        target.gazeY += addition.gazeY * scale
        target.smile += addition.smile * scale
        target.brow += addition.brow * scale
    }

    private mutating func blinkAmount() -> Double {
        let duration = 0.21
        if elapsed > blinkStart + duration {
            blinkStart = elapsed + blinkGaps[blinkIndex % blinkGaps.count]
            blinkIndex += 1
        }
        let time = elapsed - blinkStart
        if time < 0 || time > duration { return 0 }
        if time < 0.075 { return smooth(time / 0.075) }
        if time < 0.105 { return 1 }
        return 1 - smooth((time - 0.105) / 0.105)
    }

    private func smooth(_ value: Double) -> Double {
        let fraction = max(0, min(1, value))
        return fraction * fraction * (3 - 2 * fraction)
    }
}
