import Foundation
import simd

struct CharacterRig: Decodable {
    let head: [Double]
    let neck: [Double]
    let pelvis: [Double]
    let eyes: [[Double]]
    let mouth: [Double]
    let arm: [[Double]]
    let armRadius: Double

    var arm2: [[Double]] {
        let axis = pelvis[0]
        var points: [[Double]] = []
        for point in arm {
            let mirroredX = 2 * axis - point[0]
            points.append([mirroredX, point[1]])
        }
        return points
    }

    var isValid: Bool {
        if head.count != 2 || neck.count != 2 || pelvis.count != 2 || mouth.count != 4 {
            return false
        }
        if arm.count != 3 || armRadius <= 0 || armRadius > 0.2 {
            return false
        }
        var values = head + neck + pelvis + mouth
        for point in arm {
            if point.count != 2 { return false }
            values += point
        }
        for eye in eyes {
            if eye.count != 4 { return false }
            values += eye
        }
        for value in values {
            if !value.isFinite || value < 0 || value > 1 { return false }
        }
        return eyes.count <= 2
    }
}

struct CharacterRigCatalog: Decodable {
    let avatars: [String: CharacterRig]
}

struct CharacterVertex {
    let point: SIMD2<Double>
    let headWeight: Double
    let bodyWeight: Double
    let chestWeight: Double
    let armWeight: Double
    let forearmWeight: Double
    let arm2Weight: Double
    let forearm2Weight: Double
    let jawWeight: Double
}

struct CharacterMesh {
    static let columns = 40
    static let rows = 80
    let source: [SIMD2<Float>]
    let vertices: [CharacterVertex]
    let rig: CharacterRig
    let aspect: Double

    init(rig: CharacterRig, aspect: Double) {
        self.rig = rig
        self.aspect = aspect
        var grid: [SIMD2<Float>] = []
        var skin: [CharacterVertex] = []
        let neckY = rig.neck[1]
        let shoulder = SIMD2(rig.arm[0][0], rig.arm[0][1])
        let elbow = SIMD2(rig.arm[1][0], rig.arm[1][1])
        let wrist = SIMD2(rig.arm[2][0], rig.arm[2][1])
        let shoulder2 = SIMD2(rig.arm2[0][0], rig.arm2[0][1])
        let elbow2 = SIMD2(rig.arm2[1][0], rig.arm2[1][1])
        let wrist2 = SIMD2(rig.arm2[2][0], rig.arm2[2][1])
        for row in 0...Self.rows {
            for column in 0...Self.columns {
                let u = Double(column) / Double(Self.columns)
                let v = Double(row) / Double(Self.rows)
                let point = SIMD2(u, 1 - v)
                let headWeight = Self.smooth((neckY + 0.025 - point.y) / 0.085)
                let chestX = (point.x - rig.neck[0]) / 0.26
                let chestY = (point.y - (neckY + 0.09)) / 0.16
                let chestWeight = exp(-chestX * chestX - chestY * chestY)
                let armDistance = min(Self.distance(point, shoulder, elbow, aspect), Self.distance(point, elbow, wrist, aspect))
                let forearmDistance = Self.distance(point, elbow, wrist, aspect)
                let belowShoulder = Self.smooth((point.y - shoulder.y + 0.015) / 0.06)
                let armWeight = exp(-pow(armDistance / rig.armRadius, 2)) * belowShoulder
                let belowElbow = Self.smooth((point.y - elbow.y + 0.01) / 0.07)
                let forearmWeight = exp(-pow(forearmDistance / rig.armRadius, 2)) * belowElbow
                let armDistance2 = min(Self.distance(point, shoulder2, elbow2, aspect), Self.distance(point, elbow2, wrist2, aspect))
                let forearmDistance2 = Self.distance(point, elbow2, wrist2, aspect)
                let belowShoulder2 = Self.smooth((point.y - shoulder2.y + 0.015) / 0.06)
                let arm2Weight = exp(-pow(armDistance2 / rig.armRadius, 2)) * belowShoulder2
                let belowElbow2 = Self.smooth((point.y - elbow2.y + 0.01) / 0.07)
                let forearm2Weight = exp(-pow(forearmDistance2 / rig.armRadius, 2)) * belowElbow2
                let mouthX = (point.x - rig.mouth[0]) / max(rig.mouth[2], 0.01)
                let mouthY = (point.y - rig.mouth[1]) / max(rig.mouth[3], 0.01)
                let jawWeight = exp(-mouthX * mouthX * 1.8 - mouthY * mouthY * 0.7)
                grid.append(SIMD2(Float(u), Float(v)))
                let bodyWeight = Self.smooth((0.88 - point.y) / 0.36)
                skin.append(CharacterVertex(point: point, headWeight: headWeight, bodyWeight: bodyWeight,
                                            chestWeight: chestWeight, armWeight: armWeight,
                                            forearmWeight: forearmWeight, arm2Weight: arm2Weight,
                                            forearm2Weight: forearm2Weight, jawWeight: jawWeight))
            }
        }
        source = grid
        vertices = skin
    }

    func destinations(for pose: CharacterPose) -> [SIMD2<Float>] {
        let neck = SIMD2(rig.neck[0], rig.neck[1])
        let shoulder = SIMD2(rig.arm[0][0], rig.arm[0][1])
        let elbow = SIMD2(rig.arm[1][0], rig.arm[1][1])
        let shoulder2 = SIMD2(rig.arm2[0][0], rig.arm2[0][1])
        let elbow2 = SIMD2(rig.arm2[1][0], rig.arm2[1][1])
        let pelvis = SIMD2(rig.pelvis[0], rig.pelvis[1])
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(vertices.count)
        for vertex in vertices {
            let point = vertex.point
            var moved = point
            let head = rotated(point, around: neck, radians: pose.headAngle)
            let headShift = SIMD2(pose.headX, pose.headY)
            moved += (head - point + headShift) * vertex.headWeight
            moved.y -= 0.0017 * pose.breath * vertex.chestWeight
            moved.x += (point.x - neck.x) * 0.004 * pose.breath * vertex.chestWeight
            moved = rotated(moved, around: elbow, radians: pose.forearmAngle * vertex.forearmWeight)
            moved = rotated(moved, around: shoulder, radians: pose.armAngle * vertex.armWeight)
            moved = rotated(moved, around: elbow2, radians: pose.forearm2Angle * vertex.forearm2Weight)
            moved = rotated(moved, around: shoulder2, radians: pose.arm2Angle * vertex.arm2Weight)
            let jawShift = pose.jaw * rig.mouth[3] * 0.6 * vertex.jawWeight
            moved.y += jawShift
            let body = rotated(moved, around: pelvis, radians: pose.bodyAngle)
            moved += (body - moved + SIMD2(pose.bodyX, pose.bodyY)) * vertex.bodyWeight
            result.append(SIMD2(Float(moved.x), Float(1 - moved.y)))
        }
        return result
    }

    private func rotated(_ point: SIMD2<Double>, around pivot: SIMD2<Double>, radians: Double) -> SIMD2<Double> {
        let deltaX = (point.x - pivot.x) * aspect
        let deltaY = point.y - pivot.y
        let x = deltaX * cos(radians) - deltaY * sin(radians)
        let y = deltaX * sin(radians) + deltaY * cos(radians)
        return SIMD2(pivot.x + x / aspect, pivot.y + y)
    }

    private static func distance(_ point: SIMD2<Double>, _ start: SIMD2<Double>, _ end: SIMD2<Double>, _ aspect: Double) -> Double {
        let p = SIMD2(point.x * aspect, point.y)
        let a = SIMD2(start.x * aspect, start.y)
        let b = SIMD2(end.x * aspect, end.y)
        let segment = b - a
        let length = max(simd_dot(segment, segment), 0.00001)
        let fraction = max(0, min(1, simd_dot(p - a, segment) / length))
        return simd_length(p - (a + segment * fraction))
    }

    private static func smooth(_ value: Double) -> Double {
        let fraction = max(0, min(1, value))
        return fraction * fraction * (3 - 2 * fraction)
    }
}
