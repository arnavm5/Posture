import Foundation
import simd
import UserNotifications

/// Regression tests for the issues found in code review.
func reviewFixTests() {
    print("Code-review regressions")
    let g0 = SIMD3<Double>(0, 0, -1)
    let dt = 0.04

    test("a saved calibration is found even when the earbud can't be identified, and older ones still load") {
        let keys = [HeadCalibration.key(.unknown, .sitting), HeadCalibration.key(.left, .sitting), HeadCalibration.key(.left, .standing)]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let unknown = HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false, earbud: .unknown)
        unknown.save()
        expect(HeadCalibration.best(for: .unknown, mode: .sitting) == unknown, "loaded at launch with no earbud info")
        expect(HeadCalibration.best(for: .unknown, mode: .standing) == unknown, "standing falls back to sitting")
        expect(HeadCalibration.best(for: .left, mode: .sitting) == unknown, "a left-earbud stream still finds it (e.g. a migrated calibration)")
        var left = unknown
        left.earbud = .left
        left.neutralGravity = simd_normalize(SIMD3(0.1, 0, -1))
        left.save()
        expect(HeadCalibration.best(for: .left, mode: .standing) == left, "the earbud's own calibration wins")
    }

    test("check-ins carry Yes / No buttons (installed at launch by Notifier.configure)") {
        let c = Notifier.checkInCategoryDefinition()
        expect(c.identifier == Notifier.checkInCategory)
        expect(c.actions.map(\.identifier) == [Notifier.hunchedAction, Notifier.fineAction], "\(c.actions.map(\.identifier))")
        Notifier.configure()          // no app bundle in the test runner: must be a safe no-op
    }

    test("a reset isn't undone by a movement that starts right after it") {
        let cal = HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0), leverArm: .zero, leverFitted: false)
        var e = PostureEstimator(calibration: cal)
        func grav(_ p: Double) -> SIMD3<Double> { let a = p * .pi / 180; return SIMD3(0, sin(a), -cos(a)) }
        func feed(_ g: SIMD3<Double>, _ a: SIMD3<Double>, _ seconds: Double) {
            var t = 0.0
            while t < seconds { e.ingest(gravity: g, translational: a, omega: .zero, dt: dt); t += dt }
        }
        feed(g0, .zero, 1)
        var t = 0.0
        while t < 1.2 {
            let phase: Double = 2 * Double.pi * t / 1.2
            let peak: Double = 0.06 * 2 * Double.pi / 1.44
            let forward: Double = peak * sin(phase)
            e.ingest(gravity: g0, translational: SIMD3<Double>(0, forward, 0), omega: .zero, dt: dt)
            t += dt
        }
        feed(g0, .zero, 1)
        var p = 0.0
        while p < 25 { p += 0.5; e.ingest(gravity: grav(p), translational: .zero, omega: .zero, dt: dt) }   // tip the head while slouched
        t = 0                                                     // sit back up fast (25° → 0°): the "sat up" reset
        while t < 0.6 { e.ingest(gravity: grav(25 * (1 - t / 0.6)), translational: SIMD3(0, -0.4 * sin(2 * .pi * t / 0.6), 0), omega: .zero, dt: dt); t += dt }
        var settled = 0.0
        while settled < 1.0 && !e.isStill { e.ingest(gravity: g0, translational: .zero, omega: .zero, dt: dt); settled += dt }
        feed(g0, .zero, 0.12)                                     // …and shift again almost immediately
        t = 0
        while t < 0.5 { e.ingest(gravity: g0, translational: SIMD3(0, 0.3 * sin(2 * .pi * t / 0.5), 0), omega: .zero, dt: dt); t += dt }
        feed(g0, .zero, 1.5)
        let r = e.reading(gravity: g0)
        expectNear(r.forwardCM, 1.2, tolerance: 0.6, "only the quick shift's own ~1.2 cm, not the old slouch")
    }

    test("Zero isn't undone by a movement right after it") {
        var tr = RelativePositionTracker()
        func move(_ d: Double, _ T: Double) {
            var s = 0.0
            while s < T { tr.ingest(worldAccel: SIMD3(0, 0, d * 2 * .pi / (T * T) * sin(2 * .pi * s / T)), dt: dt); s += dt }
        }
        func still(_ s: Double) { var x = 0.0; while x < s { tr.ingest(worldAccel: .zero, dt: dt); x += dt } }
        still(2); move(0.5, 1.6); still(2)
        expect(tr.upCM > 40, "stood up first (\(tr.upCM))")
        tr.zero()
        still(0.1); move(0.02, 0.5); still(2)                     // a small shift 0.1 s after Zero
        expectNear(tr.upCM, 2, tolerance: 2, "only the new 2 cm, not the old 50 cm")
    }

    test("the first reading after an AirPods dropout is treated as a gap") {
        let step = HeadphoneMotion.timeStep(previous: nil, now: 123.4, afterDropout: true)
        expect(step > SpikeFilter.gapAfter, "dropout step \(step)")
        expect(HeadphoneMotion.timeStep(previous: nil, now: 1, afterDropout: false) == 0.04, "first sample ever: normal step")
        expect(abs(HeadphoneMotion.timeStep(previous: 1.00, now: 1.04, afterDropout: false) - 0.04) < 1e-9)
        var f = SpikeFilter()
        var flagged = false
        for d in [0.04, 0.04, step, 0.04, 0.04] {
            if let o = f.push(MotionSample(gravity: g0, accel: .zero, omega: .zero, rotation: matrix_identity_double3x3, dt: d)), o.gap { flagged = true }
        }
        expect(flagged, "spike filter flags the gap so nothing is differenced across the dropout")
    }

    test("a quick second slouch still dings on time (no minimum gap)") {
        var rule = SlouchDingRule()
        rule.holdSeconds = 1
        let t0 = Date()
        var dings: [Int] = []
        let pattern = [(true, 3), (false, 10), (true, 5)]          // slouch, sit well 10 s, slouch again at t=13
        var s = 0
        for (slouching, n) in pattern {
            for _ in 0..<n { if rule.tick(slouching: slouching, now: t0 + Double(s)) { dings.append(s) }; s += 1 }
        }
        expect(dings == [1, 14], "dings at \(dings)")
    }

    test("answers from the same moment are never split between training and testing") {
        let t0 = Date()
        var ex: [HunchExample] = []
        for i in 0..<30 {
            let base = t0.addingTimeInterval(Double(i) * 300)
            for j in 0..<3 { ex.append(HunchExample(features: [Double](repeating: 0, count: 8), hunched: i % 2 == 0, date: base + Double(j) * 6)) }
        }
        let fold = HunchTrainer.foldAssignment(ex, folds: 5)
        let moment = HunchTrainer.momentIDs(ex)
        for (i, a) in moment.enumerated() { for (j, b) in moment.enumerated() where a == b { expect(fold[i] == fold[j]) } }
        expect(Set(fold).count == 5, "all 5 folds used")
        let ordered = ex.indices.sorted { ex[$0].date < ex[$1].date }.map { fold[$0] }
        expect(ordered == ordered.sorted(), "folds are blocks of time")
    }

    test("a corrupted head model file is rejected instead of crashing") {
        var bad = Data("glTF".utf8)
        for v: UInt32 in [2, 1000, 1_000_000, 0x4E4F_534A] { withUnsafeBytes(of: v.littleEndian) { bad.append(contentsOf: $0) } }
        bad.append(Data("{\"accessors\":[]}".utf8))               // claims a 1 MB JSON chunk, file is ~40 bytes
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("truncated-\(UUID().uuidString).glb")
        try bad.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var threw = false
        do { _ = try GLBLoader.loadGeometry(url: url) } catch { threw = true }
        expect(threw)
    }
}
