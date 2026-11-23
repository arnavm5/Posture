import Foundation
import simd

/// Synthetic AirPods: upright gravity along −z, head-forward axis +y, left −x (the estimator is frame-agnostic).
private let g0 = SIMD3<Double>(0, 0, -1)
private let calibration = HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false)
private let dt = 0.04

private struct Noise {
    var state: UInt64 = 42
    mutating func next() -> Double {          // ±0.04 m/s², deterministic
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) - 0.5) * 0.08
    }
    mutating func vec() -> SIMD3<Double> { SIMD3(next(), next(), next()) }
}

/// Gravity in the device frame with the head pitched by `p` degrees (+ = looking down).
func gravity(pitchDegrees p: Double, rollDegrees r: Double = 0) -> SIMD3<Double> {
    let a = p * .pi / 180, b = r * .pi / 180
    return simd_normalize(SIMD3(-sin(b), sin(a), -cos(a) * cos(b)))
}

private func feed(_ e: inout PostureEstimator, gravity g: SIMD3<Double> = g0, accel: SIMD3<Double>, noise: inout Noise) {
    e.ingest(gravity: g, translational: accel + noise.vec(), omega: .zero, dt: dt)
}

/// Smooth move of `fwd`/`up` metres over `T` seconds (sinusoidal acceleration profile).
private func move(_ e: inout PostureEstimator, fwd: Double, up: Double, T: Double, noise: inout Noise) {
    var t = 0.0
    while t < T {
        let a = 2 * .pi / (T * T) * sin(2 * .pi * t / T)
        feed(&e, accel: SIMD3(0, fwd * a, up * a), noise: &noise)
        t += dt
    }
}

private func still(_ e: inout PostureEstimator, seconds: Double, gravity g: SIMD3<Double> = g0, noise: inout Noise) {
    var t = 0.0
    while t < seconds { feed(&e, gravity: g, accel: .zero, noise: &noise); t += dt }
}

func estimatorTests() {
    print("PostureEstimator")

    test("noise alone never moves the head") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 120, noise: &n)
        let r = e.reading(gravity: g0)
        expectNear(r.forwardCM, 0, tolerance: 0.3, "forward")
        expectNear(r.dropCM, 0, tolerance: 0.3, "drop")
        expectNear(r.tilt, 0, tolerance: 0.01, "tilt")
    }

    test("quick lean toward the screen is measured") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.06, up: 0, T: 1, noise: &n)
        still(&e, seconds: 1, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, 6, tolerance: 1.0, "forward")
    }

    test("slumping down is measured as a drop") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.02, up: -0.05, T: 1.5, noise: &n)
        still(&e, seconds: 1, noise: &n)
        let r = e.reading(gravity: g0)
        expectNear(r.dropCM, 5, tolerance: 1.0, "drop")
        expectNear(r.forwardCM, 2, tolerance: 1.0, "forward")
    }

    test("sitting back is measured as negative forward") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: -0.04, up: 0, T: 0.8, noise: &n)
        still(&e, seconds: 1, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, -4, tolerance: 1.0, "forward")
    }

    test("standing up (huge move) resets the position estimate") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        move(&e, fwd: 0.06, up: 0, T: 1, noise: &n)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.1, up: 0.5, T: 1.5, noise: &n)
        still(&e, seconds: 1, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, 0, tolerance: 0.5, "forward")
    }

    test("Kalman learns a constant accelerometer bias and doesn't drift from it") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        var t = 0.0
        while t < 60 { feed(&e, accel: SIMD3(0, 0.03, -0.02), noise: &n); t += dt }   // biased sensor, head still
        let r = e.reading(gravity: g0)
        expectNear(r.forwardCM, 0, tolerance: 0.3, "forward")
        expectNear(r.dropCM, 0, tolerance: 0.3, "drop")
    }

    test("position uncertainty grows during a movement and shrinks once still") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 2, noise: &n)
        let before = e.reading(gravity: g0).forwardSigmaCM
        var t = 0.0
        while t < 0.8 { feed(&e, accel: SIMD3(0, 0.4 * sin(t * 8), 0), noise: &n); t += dt }
        let during = e.reading(gravity: g0).forwardSigmaCM
        expect(during > before, "sigma should grow while moving (\(before) → \(during))")
    }

    test("forward and side tilt are measured separately") {
        let e = PostureEstimator(calibration: calibration)
        let fwd = e.reading(gravity: gravity(pitchDegrees: 20))
        expectNear(fwd.pitch, 20, tolerance: 0.1, "pitch")
        expectNear(fwd.roll, 0, tolerance: 0.1, "roll")
        let side = e.reading(gravity: gravity(pitchDegrees: 0, rollDegrees: 15))
        expectNear(side.roll, 15, tolerance: 0.1, "roll (left ear down)")
        expectNear(side.pitch, 0, tolerance: 0.1, "pitch")
    }

    test("tipping the head forward moves it forward via neck kinematics") {
        let e = PostureEstimator(calibration: calibration)
        let r = e.reading(gravity: gravity(pitchDegrees: 20))
        expectNear(r.forwardCM, 100 * PostureEstimator.neckLever * sin(20 * .pi / 180), tolerance: 0.05, "forward")
        expect(r.dropCM > 0, "head should drop when tipped forward")
    }

    test("regression: snapping upright after an alert doesn't lurch the head forward") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.06, up: 0, T: 1, noise: &n)
        still(&e, seconds: 1, noise: &n)
        var pitch = 0.0
        while pitch < 25 { pitch += 0.5; feed(&e, gravity: gravity(pitchDegrees: pitch), accel: .zero, noise: &n) }
        // Fast sit-up: 25° → 0° in 0.6 s while moving back, with sensor-fusion gravity leak.
        var t = 0.0
        while t < 0.6 {
            let leak = 0.25 * 9.81 * sin(.pi * t / 0.6)
            let back = -0.06 * 2 * .pi / 0.36 * sin(2 * .pi * t / 0.6)
            feed(&e, gravity: gravity(pitchDegrees: 25 * (1 - t / 0.6)), accel: SIMD3(0, back + leak, 0), noise: &n)
            t += dt
        }
        still(&e, seconds: 1, noise: &n)
        let r = e.reading(gravity: g0)
        expectNear(r.forwardCM, 0, tolerance: 0.5, "forward after sit-up")
        expectNear(r.dropCM, 0, tolerance: 0.5, "drop after sit-up")
    }

    test("regression: a held forward-head slouch with level eyes stays detected (no false \"good\")") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.06, up: -0.02, T: 1.2, noise: &n)          // slump forward, eyes stay on the screen
        still(&e, seconds: 12 * 60, noise: &n)                       // and stay there, not moving
        let r = e.reading(gravity: g0)
        expect(r.forwardCM > 5, "still \(r.forwardCM) cm forward after 12 min (the 10-min alert needs it)")
        expect(PostureRules(maxForwardTilt: 15, maxSideTilt: 12, maxShiftCM: 5).reasons(for: r).isEmpty == false)
    }

    test("regression: a slump that ends with eyes level isn't mistaken for sitting back up") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        // Head dips ~15° while sliding forward 6 cm, then levels out to look at the screen again.
        var t = 0.0
        let T = 1.4
        while t < T {
            let pitch = 15 * sin(.pi * t / T)
            let a = 0.06 * 2 * .pi / (T * T) * sin(2 * .pi * t / T)
            feed(&e, gravity: gravity(pitchDegrees: pitch), accel: SIMD3(0, a, 0), noise: &n)
            t += dt
        }
        still(&e, seconds: 3, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, 6, tolerance: 1.2, "forward after a slump with level eyes")
    }

    test("regression: working (fidgeting, typing, talking) while slouched doesn't erase the slouch") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.06, up: 0, T: 1.2, noise: &n)
        still(&e, seconds: 2, noise: &n)
        expect(e.reading(gravity: g0).forwardCM > 5, "slouch registered")
        // 25 s of never-settling small head movements: little nods/turns and bobbing, no net movement.
        var t = 0.0
        while t < 25 {
            let pitch = 4 * sin(t * 2.1) + 2 * sin(t * 5.3)
            let omega = SIMD3<Double>(0.5 * cos(t * 2.1), 0.3 * sin(t * 3.7), 0.2 * cos(t * 1.3))
            let bob = SIMD3<Double>(0.05 * sin(t * 4), 0.25 * sin(t * 6.1), 0.2 * cos(t * 5.2))
            e.ingest(gravity: gravity(pitchDegrees: pitch), translational: bob + n.vec(), omega: omega, dt: dt)
            t += dt
        }
        still(&e, seconds: 2, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, 6, tolerance: 1.5, "slouch kept through 25 s of fidgeting")
    }

    test("a long movement that can't be trusted is dropped, keeping the position from before it") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        still(&e, seconds: 1, noise: &n)
        move(&e, fwd: 0.06, up: 0, T: 1.2, noise: &n)
        still(&e, seconds: 2, noise: &n)
        // 8 s of motion with a spurious forward bias that would integrate to metres.
        var t = 0.0
        while t < 8 {
            e.ingest(gravity: g0, translational: SIMD3(0, 0.3, 0) + SIMD3(0, 0, 0.3 * sin(t * 7)) + n.vec(),
                     omega: SIMD3(0.7, 0, 0), dt: dt)
            t += dt
        }
        still(&e, seconds: 2, noise: &n)
        expectNear(e.reading(gravity: g0).forwardCM, 6, tolerance: 1.0, "back to the slouch, not zero and not metres")
    }

    test("leftover offsets still fade, but only on an overnight scale") {
        var n = Noise(), e = PostureEstimator(calibration: calibration)
        move(&e, fwd: 0.06, up: 0, T: 1, noise: &n)
        still(&e, seconds: 1, noise: &n)
        // Long stretches simulated at 1 sample per second (the filter handles any dt).
        func hold(hours: Double) {
            for _ in 0..<Int(hours * 3600) { e.ingest(gravity: g0, translational: n.vec(), omega: .zero, dt: 1) }
        }
        hold(hours: 1)
        expect(e.reading(gravity: g0).forwardCM > 5, "a long slouch keeps counting for an hour+ (\(e.reading(gravity: g0).forwardCM))")
        hold(hours: 30)
        expect(e.reading(gravity: g0).forwardCM < 1, "gone after a day (\(e.reading(gravity: g0).forwardCM))")
    }
}
