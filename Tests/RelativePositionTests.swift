import Foundation
import simd

private struct Noise {
    var state: UInt64 = 7
    mutating func scalar(_ amp: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) - 0.5) * 2 * amp
    }
    mutating func vec(_ amp: Double = 0.04) -> SIMD3<Double> { SIMD3(scalar(amp), scalar(amp), scalar(amp)) }
}

private let dt = 0.04

/// Smooth move by `d` metres (world frame) over T seconds, on top of sensor noise of `amp` m/s².
private func move(_ t: inout RelativePositionTracker, _ d: SIMD3<Double>, T: Double, amp: Double = 0.04, noise: inout Noise) {
    var s = 0.0
    while s < T {
        t.ingest(worldAccel: d * (2 * .pi / (T * T) * sin(2 * .pi * s / T)) + noise.vec(amp), dt: dt)
        s += dt
    }
}

private func still(_ t: inout RelativePositionTracker, _ seconds: Double, amp: Double = 0.04, noise: inout Noise) {
    var s = 0.0
    while s < seconds { t.ingest(worldAccel: noise.vec(amp), dt: dt); s += dt }
}

/// Realistic "wearing AirPods at a desk": sensor noise plus typing vibration and small head jitter.
private func desk(_ t: inout RelativePositionTracker, _ seconds: Double, noise: inout Noise) {
    var s = 0.0
    while s < seconds {
        let typing = SIMD3<Double>(0, 0, 0.12 * sin(s * 2 * .pi * 9))          // 9 Hz tapping
        let jitter = SIMD3<Double>(0.06 * sin(s * 2 * .pi * 3.1), 0.05 * cos(s * 2 * .pi * 2.3), 0)
        t.ingest(worldAccel: typing + jitter + noise.vec(0.09), dt: dt)
        s += dt
    }
}

private func rotation(yaw: Double, pitch: Double) -> simd_double3x3 {
    let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
    let rz = simd_double3x3(rows: [SIMD3(cy, -sy, 0), SIMD3(sy, cy, 0), SIMD3(0, 0, 1)])
    let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cp, -sp), SIMD3(0, sp, cp)])
    return rx * rz
}

func relativePositionTests() {
    print("RelativePositionTracker (display only)")

    test("standing up reads about +50 cm (positive = up)") {
        var n = Noise(), t = RelativePositionTracker()
        still(&t, 2, noise: &n)
        move(&t, SIMD3(0.10, 0, 0.50), T: 1.6, noise: &n)
        still(&t, 1, noise: &n)
        expectNear(t.upCM, 50, tolerance: 5, "up")
        expectNear(t.horizontalCM, 10, tolerance: 4, "horizontal")
        expect(!t.approximate)
    }

    test("sitting back down returns near zero") {
        var n = Noise(), t = RelativePositionTracker()
        still(&t, 2, noise: &n)
        move(&t, SIMD3(0.10, 0, 0.50), T: 1.6, noise: &n)
        still(&t, 2, noise: &n)
        move(&t, SIMD3(-0.10, 0, -0.50), T: 1.4, noise: &n)
        still(&t, 1, noise: &n)
        expectNear(t.upCM, 0, tolerance: 5, "up")
        expectNear(t.horizontalCM, 0, tolerance: 5, "horizontal")
    }

    test("regression: noisy desk wearing doesn't swallow movements or lose track") {
        var n = Noise(), t = RelativePositionTracker()
        desk(&t, 30, noise: &n)                                  // learn the noise floor
        expect(!t.moving, "desk jitter alone should not count as moving (floor \(t.noiseFloor))")
        var s = 0.0, T = 1.6
        while s < T {                                            // stand up while still typing-noisy
            let a = SIMD3<Double>(0, 0, 0.5) * (2 * .pi / (T * T) * sin(2 * .pi * s / T))
            t.ingest(worldAccel: a + n.vec(0.09) + SIMD3(0, 0, 0.12 * sin(s * 2 * .pi * 9)), dt: dt)
            s += dt
        }
        desk(&t, 3, noise: &n)
        expect(!t.approximate, "should not need to skip anything")
        expectNear(t.upCM, 50, tolerance: 8, "up")
    }

    test("sitting still never drifts") {
        var n = Noise(), t = RelativePositionTracker()
        desk(&t, 300, noise: &n)
        expectNear(t.upCM, 0, tolerance: 1, "up")
        expectNear(t.horizontalCM, 0, tolerance: 1, "horizontal")
    }

    test("walking around is skipped and marked approximate, earlier moves are kept") {
        var n = Noise(), t = RelativePositionTracker()
        still(&t, 2, noise: &n)
        move(&t, SIMD3(0, 0, 0.5), T: 1.6, noise: &n)
        still(&t, 1, noise: &n)
        var s = 0.0
        while s < 14 { t.ingest(worldAccel: SIMD3(1.5 * sin(s * 11), 0.4 * cos(s * 7), 1.2 * sin(s * 13)) + n.vec(), dt: dt); s += dt }
        still(&t, 1, noise: &n)
        expect(t.approximate)
        expectNear(t.upCM, 50, tolerance: 6, "standing height kept")
        t.zero()
        expect(!t.approximate && t.upCM == 0)
    }

    test("world frame: device acceleration maps to world up for either matrix convention") {
        for transposeConvention in [false, true] {
            var frame = WorldFrame()
            let poses = [(0.0, 0.3), (0.8, -0.25), (-1.2, 0.4), (2.0, -0.3), (0.5, 0.0)]
            for (yaw, pitch) in Array(repeating: poses, count: 8).flatMap({ $0 }) {
                let deviceFromWorld = rotation(yaw: yaw, pitch: pitch)
                let reported = transposeConvention ? deviceFromWorld.transpose : deviceFromWorld
                let deviceAccel = deviceFromWorld * SIMD3(0, 0, 1) * (0.5 / 9.81)
                let w = frame.worldAcceleration(userAccel: deviceAccel, gravity: deviceFromWorld * SIMD3(0, 0, -1), rotation: reported)
                expectNear(w.z, 0.5, tolerance: 1e-6, "up")
                expectNear((w.x * w.x + w.y * w.y).squareRoot(), 0, tolerance: 1e-6, "horizontal leak")
            }
            expect(frame.useTranspose == transposeConvention, "convention should lock to \(transposeConvention)")
        }
    }

    test("world frame: once locked, horizontal moves keep their direction even with the head level") {
        var frame = WorldFrame()
        for _ in 0..<30 {                                    // tilted samples lock the convention
            let r = rotation(yaw: 0.3, pitch: 0.35)
            _ = frame.worldAcceleration(userAccel: .zero, gravity: r * SIMD3(0, 0, -1), rotation: r.transpose)
        }
        expect(frame.useTranspose == true)
        let level = rotation(yaw: 1.0, pitch: 0)             // level head: gravity can't tell conventions apart
        let east = SIMD3<Double>(1, 0, 0)
        let w = frame.worldAcceleration(userAccel: level * east / 9.81, gravity: level * SIMD3(0, 0, -1), rotation: level.transpose)
        expectNear(simd_dot(w, east), 1, tolerance: 1e-6, "direction preserved")
    }
}
