import Foundation
import simd

private let dt = 0.04

/// Rigid head rotating about a fixed pivot, about one body axis, with the earbud at `lever` from the pivot.
/// Device frame = head frame: x right, y forward, z up. Returns per-sample (gravity, accel m/s², ω).
private func rotate(axis: SIMD3<Double>, amplitude: Double, frequency: Double, seconds: Double,
                    base: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(1, 0, 0)),
                    lever: SIMD3<Double>) -> [(g: SIMD3<Double>, a: SIMD3<Double>, w: SIMD3<Double>)] {
    var out: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
    var t = 0.0
    let w0 = 2 * .pi * frequency
    // Real heads start and stop smoothly: oscillation under a sin² envelope (rest at both ends).
    func angle(_ t: Double) -> Double {
        let progress: Double = min(max(t / seconds, 0), 1)
        let envelope: Double = pow(sin(Double.pi * progress), 2)
        return amplitude * sin(w0 * t) * envelope
    }
    let h = 1e-4
    while t < seconds {
        let theta = angle(t)
        let dtheta = (angle(t + h) - angle(t - h)) / (2 * h)
        let ddtheta = (angle(t + h) - 2 * theta + angle(t - h)) / (h * h)
        let worldFromDevice = base * simd_quatd(angle: theta, axis: axis)
        let g = worldFromDevice.inverse.act(SIMD3(0, 0, -1))
        let w = axis * dtheta, alpha = axis * ddtheta
        let a = simd_cross(alpha, lever) + simd_cross(w, simd_cross(w, lever))
        out.append((g, a, w))
        t += dt
    }
    return out
}

private func rms(_ v: [SIMD3<Double>]) -> Double {
    (v.map { simd_length_squared($0) }.reduce(0, +) / Double(max(1, v.count))).squareRoot()
}

func motionProcessingTests() {
    print("Motion processing (Kalman, gyro, lever arm)")

    test("Kalman integrates constant acceleration") {
        var k = ZUPTKalman()
        var t = 0.0
        while t < 1 - 1e-9 { k.predict(accel: 0.5, dt: dt); t += dt }
        expectNear(k.position, 0.25, tolerance: 0.01, "p = ½at²")
        expectNear(k.velocity, 0.5, tolerance: 0.01, "v = at")
    }

    test("Kalman zero-velocity updates learn the bias") {
        var k = ZUPTKalman()
        for _ in 0..<500 { k.predict(accel: 0.03, dt: dt); k.zeroVelocity() }
        expectNear(k.bias, 0.03, tolerance: 0.005, "bias")
        expect(abs(k.position) < 0.01, "position stays put (\(k.position))")
    }

    test("gyro sign is confirmed from gravity, for either convention") {
        let samples = rotate(axis: SIMD3(1, 0, 0), amplitude: 0.4, frequency: 0.8, seconds: 4, lever: .zero)
        for flip in [1.0, -1.0] {
            var v = GyroSignVoter()
            for i in 1..<samples.count {
                v.observe(previousGravity: samples[i - 1].g, gravity: samples[i].g, omega: samples[i].w * flip * v.effectiveSign, dt: dt)
                if v.sign != nil { break }
            }
            // The voter sees ω already multiplied by its current guess; it should land on the guess that undoes `flip`.
            expect(v.sign == flip, "flip \(flip) → sign \(String(describing: v.sign))")
        }
    }

    test("lever-arm compensation removes the earbud's swing when nodding") {
        let lever = SIMD3<Double>(0.07, 0.01, 0.06)
        let nod = rotate(axis: SIMD3(1, 0, 0), amplitude: 0.35, frequency: 0.8, seconds: 4, lever: lever)
        var raw: [SIMD3<Double>] = [], comp: [SIMD3<Double>] = []
        var c = LeverArmCompensator()
        c.lever = lever
        for s in nod {
            if let k = c.step(gravity: s.g, accel: s.a, omega: s.w, rotation: matrix_identity_double3x3, dt: dt) {
                raw.append(k.accel); comp.append(k.translational)
            }
        }
        expect(rms(raw) > 0.15, "the swing is real: raw rms \(rms(raw)) m/s²")
        expect(rms(comp) < 0.03 * rms(raw) + 0.01, "compensated rms \(rms(comp)) vs raw \(rms(raw))")
    }

    test("lever arm is recovered from nod + turn + tilt (the calibration moves)") {
        let lever = SIMD3<Double>(0.07, -0.01, 0.06)
        var c = LeverArmCompensator()                       // lever 0 during calibration, like the app
        var fit = LeverArmFit()
        for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)] {
            for s in rotate(axis: axis, amplitude: 0.4, frequency: 0.6, seconds: 3.4, lever: lever) {
                if let k = c.step(gravity: s.g, accel: s.a, omega: s.w, rotation: matrix_identity_double3x3, dt: dt) { fit.add(k) }
            }
        }
        guard let result = fit.solve(prior: SIMD3(0, 0, 0.09)) else { return expect(false, "fit failed") }
        expect(simd_length(result.lever - lever) < 0.01, "fitted \(result.lever) vs true \(lever)")
    }

    test("end to end: nodding while looking down doesn't fake a head movement") {
        let lever = SIMD3<Double>(0.02, 0.01, 0.09)
        let cal = HeadCalibration(neutralGravity: SIMD3(0, 0, -1), forward: SIMD3(0, 1, 0), leverArm: lever, leverFitted: true)
        let down = simd_quatd(angle: -20 * .pi / 180, axis: SIMD3(1, 0, 0))       // reading posture, 20° down
        func run(compensate: Bool) -> Double {
            var c = LeverArmCompensator()
            c.lever = compensate ? lever : .zero
            var e = PostureEstimator(calibration: cal)
            let quiet = rotate(axis: SIMD3(1, 0, 0), amplitude: 0, frequency: 1, seconds: 2, base: down, lever: lever)
            let nod = rotate(axis: SIMD3(1, 0, 0), amplitude: 0.25, frequency: 0.8, seconds: 1.25, base: down, lever: lever)
            var worst = 0.0                                  // largest fake shift at any moment (what the 3D head shows)
            for s in quiet + nod + quiet {
                if let k = c.step(gravity: s.g, accel: s.a, omega: s.w, rotation: matrix_identity_double3x3, dt: dt) {
                    e.ingest(gravity: k.gravity, translational: k.translational, omega: k.omega, dt: k.dt)
                    worst = max(worst, (e.shiftForward * e.shiftForward + e.shiftUp * e.shiftUp).squareRoot() * 100)
                }
            }
            return worst
        }
        let uncompensated = run(compensate: false), compensated = run(compensate: true)
        expect(uncompensated > 1, "without compensation the nod fakes a move (\(uncompensated) cm)")
        expect(compensated < 0.5, "with compensation it doesn't (\(compensated) cm)")
    }
}
