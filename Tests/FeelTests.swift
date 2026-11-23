import AppKit
import Foundation
import SceneKit
import simd

/// A neck + head rig like the bust's, for testing the animator on its own.
@MainActor
private func rig() -> (root: SCNNode, neck: SCNNode, head: SCNNode, animator: HeadAnimator) {
    let root = SCNNode(), neck = SCNNode(), head = SCNNode()
    neck.simdPosition = HeadScene.neckBase
    root.addChildNode(neck)
    head.simdPosition = HeadScene.skullBase - HeadScene.neckBase
    neck.addChildNode(head)
    let a = HeadAnimator(root: root, neck: neck, head: head, neckLength: simd_length(HeadScene.skullBase - HeadScene.neckBase))
    return (root, neck, head, a)
}

@MainActor
func feelTests(resources: URL) {
    print("Motion smoothing, rig & dings")

    test("smoothing removes jitter while the head is still") {
        let r = rig()
        var s: UInt64 = 3
        func jitter() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let top24: UInt64 = s >> 40
            let unit: Float = Float(top24) / 16777216.0                    // 2^24 → [0, 1)
            return (unit - 0.5) * 0.03
        }
        var rawSteps: [Float] = [], smoothSteps: [Float] = []
        var prevRaw: Float = 0, prevSmooth: Float = 0
        for frame in 0..<600 {                                   // 10 s at 60 fps, readings at ~25 Hz
            if frame % 2 == 0 || frame % 5 == 0 {
                let target = jitter()                             // ±0.015 rad (≈ ±0.9°) of sensor noise
                rawSteps.append(abs(target - prevRaw)); prevRaw = target
                r.animator.setTarget(rotation: simd_quatf(angle: target, axis: SIMD3(1, 0, 0)))
            }
            r.animator.advance(dt: 1.0 / 60)
            let angle = r.animator.rotation.angle * (r.animator.rotation.axis.x >= 0 ? 1 : -1)
            smoothSteps.append(abs(angle - prevSmooth)); prevSmooth = angle
        }
        let rawMean = rawSteps.reduce(0, +) / Float(rawSteps.count)
        let smoothMean = smoothSteps.reduce(0, +) / Float(smoothSteps.count)
        expect(smoothMean < rawMean * 0.2, "per-frame movement \(smoothMean) vs raw step \(rawMean)")
    }

    test("smoothing still keeps up with a real head movement") {
        let r = rig()
        r.animator.setTarget(rotation: simd_quatf(angle: 0.5, axis: SIMD3(1, 0, 0)))     // a quick ~29° nod
        var reached90: Int?
        for frame in 1...60 {
            r.animator.advance(dt: 1.0 / 60)
            if reached90 == nil, r.animator.rotation.angle >= 0.45 { reached90 = frame }
        }
        expect((reached90 ?? 999) <= 15, "reached 90% of the move in \(reached90 ?? -1) frames (≤ 0.25 s)")
    }

    test("the head always ends up exactly at the AirPods orientation (neck shares the bend)") {
        let r = rig()
        let q = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3(1, 0.5, 0.2)))
        r.animator.setTarget(rotation: q, immediate: true)
        r.animator.setTarget(forward: 1.0, immediate: true)
        let world = r.head.simdWorldOrientation
        expect(abs(abs(simd_dot(world.vector, q.vector)) - 1) < 1e-4, "head world rotation matches")
        expect(r.neck.simdWorldOrientation.angle > 0.1, "neck carries part of the bend")
    }

    test("a forward head shift bends the neck and moves the head forward (it glides, doesn't jump)") {
        let r = rig()
        let start = r.head.simdWorldPosition
        r.animator.setTarget(forward: 1.2)                       // ≈ 6 cm
        r.animator.advance(dt: 1.0 / 60)
        let firstStep = r.head.simdWorldPosition.z - start.z
        expect(firstStep > 0 && firstStep < 0.1, "first frame moves only a little (\(firstStep))")
        for _ in 0..<150 { r.animator.advance(dt: 1.0 / 60) }
        let moved = r.head.simdWorldPosition - start
        expect(moved.z > 1.0 && moved.z < 1.35, "skull base moved forward \(moved.z) units")
        expect(moved.y < 0, "and down a little, as a bending neck does")
        expect(r.animator.neckFlex > 0.3, "mostly by bending the neck (\(r.animator.neckFlex) rad)")
        expect(r.animator.lean > 0.05, "and partly by the upper body leaning in, like a real slouch (\(r.animator.lean) rad)")
    }

    test("skin weights are valid everywhere") {
        let pts = try GLBLoader.loadGeometry(url: resources.appendingPathComponent("Head.glb")).positions
        let ws = pts.map(HeadScene.skinWeights)
        expect(ws.allSatisfy { abs($0.x + $0.y + $0.z - 1) < 1e-4 && $0.min() >= -1e-6 }, "sum to 1, none negative")
        let chin = HeadScene.skinWeights(SIMD3(0, -0.7, 1.3)), throat = HeadScene.skinWeights(SIMD3(0, -1.0, 0.6))
        let nape = HeadScene.skinWeights(SIMD3(0, -0.2, -1.2)), shoulder = HeadScene.skinWeights(SIMD3(3.5, -2.8, -0.5))
        expect(chin.z > 0.7, "chin moves mostly with the head (a little neck share lets the throat bend smoothly) \(chin)")
        expect(throat.y > 0.5, "throat bends with the neck \(throat)")
        expect(nape.y > 0.6, "back of the neck bends with the neck \(nape)")
        expect(shoulder.x > 0.99, "shoulders stay put \(shoulder)")
    }

    test("regression: the neck doesn't tear when the head moves forward (no 'detached' neck)") {
        let geo = try GLBLoader.loadGeometry(url: resources.appendingPathComponent("Head.glb"))
        let pts = geo.positions
        guard let el = geo.elements.first else { return expect(false, "triangles") }
        let tris: [Int] = el.data.withUnsafeBytes { b in
            (0..<el.primitiveCount * 3).map { el.bytesPerIndex == 2 ? Int(b.load(fromByteOffset: $0 * 2, as: UInt16.self))
                                                                     : Int(b.load(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        let r = rig()
        r.animator.setTarget(rotation: simd_quatf(angle: 0.35, axis: SIMD3(1, 0, 0)), immediate: true)   // 20° nod
        r.animator.setTarget(forward: 6 * HeadScene.unitsPerCM, immediate: true)                         // 6 cm forward
        let binds = [SIMD3<Float>.zero, HeadScene.neckBase, HeadScene.skullBase]
        let mats = [r.root.simdWorldTransform, r.neck.simdWorldTransform, r.head.simdWorldTransform]
        func skin(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let w = HeadScene.skinWeights(p)
            var out = SIMD3<Float>.zero
            for b in 0..<3 {
                let local = SIMD4(p - binds[b], 1)
                let world = mats[b] * local
                out += w[b] * SIMD3(world.x, world.y, world.z)
            }
            return out
        }
        let posed = pts.map(skin)
        var worst: Float = 0
        for t in stride(from: 0, to: tris.count, by: 3) {
            for (a, b) in [(tris[t], tris[t + 1]), (tris[t + 1], tris[t + 2]), (tris[t + 2], tris[t])] {
                let before = simd_length(pts[a] - pts[b])
                guard before > 1e-4 else { continue }
                worst = max(worst, simd_length(posed[a] - posed[b]) / before)
            }
        }
        expect(worst < 1.8, "worst edge stretch \(worst)× in a typical slouch (tearing showed up as 3×+)")
    }

    test("the ding plays exactly the chosen number of seconds after the slouch is detected") {
        for delay in [0, 1, 3, 5, 12] {
            var rule = SlouchDingRule()
            rule.holdSeconds = delay
            let t0 = Date()
            var dingAt: Int?
            for s in 0..<40 where rule.tick(slouching: true, now: t0 + Double(s)) { dingAt = s }
            expect(dingAt == delay, "delay \(delay) s → dinged \(dingAt.map { "\($0) s" } ?? "never") after detection")
        }
    }

    test("one ding per slouch, however long it lasts") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dings = 0
        for s in 0..<600 where rule.tick(slouching: true, now: t0 + Double(s)) { dings += 1 }
        expect(dings == 1, "got \(dings)")
    }

    test("regression: slouching again after sitting well dings again (no 2-minute silence)") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dingTimes: [Int] = []
        // slouch 20 s, sit well 15 s, slouch again 20 s, sit well 12 s, slouch again
        let pattern = [(true, 20), (false, 15), (true, 20), (false, 12), (true, 10)]
        var s = 0
        for (slouching, seconds) in pattern {
            for _ in 0..<seconds {
                if rule.tick(slouching: slouching, now: t0 + Double(s)) { dingTimes.append(s) }
                s += 1
            }
        }
        expect(dingTimes == [1, 36, 68], "a ding for each new slouch, 1 s after it starts (got \(dingTimes))")
    }

    test("hovering right at the limit doesn't nag") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dings = 0
        for s in 0..<180 where rule.tick(slouching: (s / 3) % 2 == 0, now: t0 + Double(s)) { dings += 1 }  // in/out every 3 s
        expect(dings == 1, "3 minutes of flickering in and out → \(dings) ding(s)")
    }

    test("chimes are valid, short, gentle sounds") {
        let data = Chime.wav(notes: [(1318.5, 0)], length: 0.9, volume: 0.4)
        expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        expect(data.count == 44 + Int(0.9 * 44_100) * 2)
        let samples: [Int16] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        expect(peak > 6_000 && peak < 24_000, "clearly audible but not harsh (peak \(peak) of 32767)")
        expect(abs(Int(samples.last!)) < 50, "fades out without a click")
        expect(Chime.gentle != nil && Chime.alert != nil, "macOS can play both")
    }
}

func headPoseTests() {
    print("3D head pose")
    let cal = HeadCalibration(neutralGravity: SIMD3(0, 0, -1), forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false)
    let up = SIMD3<Float>(0, 1, 0), face = SIMD3<Float>(0, 0, 1)

    test("regression: sitting at your calibrated pose shows an upright head right after launch") {
        let q = HeadScene.headRotation(gravity: SIMD3(0, 0, -1), calibration: cal, yaw: 0)
        expect(simd_length(q.act(up) - up) < 1e-5 && simd_length(q.act(face) - face) < 1e-5, "upright, facing forward")
    }

    test("looking down tips the head forward by the same angle") {
        let a = 20.0 * .pi / 180
        let q = HeadScene.headRotation(gravity: SIMD3(0, sin(a), -cos(a)), calibration: cal, yaw: 0)
        let f = q.act(face)
        expectNear(Double(asin(-f.y)), a, tolerance: 1e-4, "face points down 20°")
        expectNear(Double(abs(f.x)), 0, tolerance: 1e-5, "no sideways tilt")
    }

    test("left ear toward left shoulder tilts the head to its left") {
        let a = 15.0 * .pi / 180
        let left = cal.left
        let g = simd_normalize(SIMD3(0, 0, -1) * cos(a) + left * sin(a))      // gravity shifts toward the left ear
        let u = HeadScene.headRotation(gravity: g, calibration: cal, yaw: 0).act(up)
        expect(u.x > 0.2, "crown moves to the model's left (+x): \(u)")
        expectNear(Double(asin(u.x)), a, tolerance: 1e-4, "by 15°")
    }

    test("turning only rotates about the vertical") {
        let q = HeadScene.headRotation(gravity: SIMD3(0, 0, -1), calibration: cal, yaw: 0.5)
        expect(simd_length(q.act(up) - up) < 1e-5, "stays upright while turning")
        expectNear(Double(atan2(q.act(face).x, q.act(face).z)), 0.5, tolerance: 1e-4, "turned 0.5 rad")
    }
}
