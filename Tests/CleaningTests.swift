import Foundation
import simd

private func sample(accel: SIMD3<Double> = .zero, omega: SIMD3<Double> = .zero,
                    gravity: SIMD3<Double> = SIMD3(0, 0, -1), dt: Double = 0.04) -> MotionSample {
    MotionSample(gravity: gravity, accel: accel, omega: omega, rotation: matrix_identity_double3x3, dt: dt)
}

func cleaningTests() {
    print("Raw stream cleaning & neutral re-centering")

    test("a one-sample acceleration glitch is removed") {
        var f = SpikeFilter()
        var out: [MotionSample] = []
        for i in 0..<10 {
            let a: SIMD3<Double> = i == 5 ? SIMD3(0, 6, 0) : SIMD3(0, 0.05, 0)     // one corrupted packet
            if let o = f.push(sample(accel: a)) { out.append(o) }
        }
        expect(out.count == 8, "output is one sample behind (\(out.count))")
        expect(out.map { simd_length($0.accel) }.max()! < 0.1, "glitch replaced by its neighbours")
        expect(f.spikesRemoved == 1)
    }

    test("real movements pass through untouched") {
        var f = SpikeFilter()
        let input = (0..<40).map { i -> SIMD3<Double> in
            let t = Double(i) * 0.04
            return i < 10 ? .zero : SIMD3(0, 3 * sin(2 * .pi * (t - 0.4) / 0.8), 0)     // a sudden, strong lean
        }
        var out: [SIMD3<Double>] = []
        for a in input { if let o = f.push(sample(accel: a)) { out.append(o.accel) } }
        let maxDiff = zip(out, input.dropFirst()).map { simd_length($0 - $1) }.max()!
        expect(maxDiff < 1e-9, "unchanged (max difference \(maxDiff))")
        expect(f.spikesRemoved == 0)
    }

    test("a gravity glitch is removed and stays unit length") {
        var f = SpikeFilter()
        var worst = 0.0
        for i in 0..<10 {
            let g: SIMD3<Double> = i == 4 ? simd_normalize(SIMD3(0.6, 0, -1)) : SIMD3(0, 0, -1)   // 31° jump for one sample
            if let o = f.push(sample(gravity: g)) {
                worst = max(worst, acos(min(1, -o.gravity.z)))
                expect(abs(simd_length(o.gravity) - 1) < 1e-9)
            }
        }
        expect(worst < 0.01, "worst angle \(worst * 180 / .pi)°")
    }

    test("dropped samples are flagged as a gap, not integrated across") {
        var f = SpikeFilter()
        var out: [MotionSample] = []
        for dt in [0.04, 0.04, 0.04, 0.9, 0.04, 0.04] { if let o = f.push(sample(dt: dt)) { out.append(o) } }
        let gap = out.first { $0.gap }
        expect(gap != nil && gap!.dt <= 0.05, "gap flagged with a normal time step")
        expect(f.gaps == 1)
    }

    test("end to end: glitches no longer fake head movement") {
        let cal = HeadCalibration(neutralGravity: SIMD3(0, 0, -1), forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false)
        func run(filtered: Bool) -> Double {
            var e = PostureEstimator(calibration: cal)
            var f = SpikeFilter()
            var s: UInt64 = 5
            for i in 0..<(60 * 25) {                                   // a minute sitting still
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let glitch = i % 47 == 0 ? SIMD3<Double>(0, 4, 0) : .zero       // a corrupted packet every ~2 s
                let noise = SIMD3<Double>(0, Double(s >> 40) / Double(1 << 24) - 0.5, 0) * 0.06
                let raw = sample(accel: glitch + noise)
                if filtered {
                    if let c = f.push(raw) { e.ingest(gravity: c.gravity, translational: c.accel, omega: c.omega, dt: c.dt) }
                } else {
                    e.ingest(gravity: raw.gravity, translational: raw.accel, omega: raw.omega, dt: raw.dt)
                }
            }
            return abs(e.reading(gravity: SIMD3(0, 0, -1)).forwardCM)
        }
        let without = run(filtered: false), with = run(filtered: true)
        expect(without > 1, "unfiltered glitches fake a move (\(without) cm)")
        expect(with < 0.3, "filtered stays still (\(with) cm)")
    }

    let cal = HeadCalibration(neutralGravity: SIMD3(0, 0, -1), forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false)
    func gravity(pitch p: Double = 0, roll r: Double = 0) -> SIMD3<Double> {
        let a = p * .pi / 180, b = r * .pi / 180
        return simd_normalize(SIMD3(-sin(b), sin(a), -cos(a) * cos(b)))
    }

    test("the neutral pose follows a small AirPod shift while you sit well") {
        var e = PostureEstimator(calibration: cal)
        let shifted = gravity(roll: 3)                                    // earbud re-seated 3° differently
        expectNear(e.reading(gravity: shifted).roll, 3, tolerance: 0.05, "before")
        for _ in 0..<(45 * 60) { e.adaptNeutral(toward: shifted, dt: 1) }
        expectNear(e.reading(gravity: shifted).roll, 0, tolerance: 0.3, "after 45 min sitting well")
        expect(abs(simd_dot(e.calibration.forward, simd_normalize(e.calibration.neutralGravity))) < 1e-9, "axes stay perpendicular")
    }

    test("it never strays more than 4° from your calibration") {
        var e = PostureEstimator(calibration: cal)
        var g = gravity(pitch: 0)
        for step in 0..<(3 * 3600) {                                     // a slow 10° creep over 3 hours
            g = gravity(pitch: 10 * Double(step) / (3 * 3600))
            e.adaptNeutral(toward: g, dt: 1)
        }
        expect(e.neutralDriftDegrees <= 4.0001, "drift \(e.neutralDriftDegrees)°")
        expect(e.reading(gravity: g).pitch > 5.9, "a slow creep still shows (\(e.reading(gravity: g).pitch)°)")
    }

    test("a real slouch is never absorbed") {
        var e = PostureEstimator(calibration: cal)
        for _ in 0..<3600 { e.adaptNeutral(toward: gravity(pitch: 20), dt: 1) }
        expect(e.neutralDriftDegrees < 0.01, "20° away: no adaptation (\(e.neutralDriftDegrees)°)")
        expectNear(e.reading(gravity: gravity(pitch: 20)).pitch, 20, tolerance: 0.01)
    }
}
