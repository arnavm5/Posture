import Foundation
import simd

private let dt = 0.04

/// Smooth vertical move of `d` metres over T seconds into a fresh/ongoing tracker, then settle.
private func rise(_ t: inout RelativePositionTracker, _ d: Double, T: Double = 1.6) {
    var s = 0.0
    while s < T { t.ingest(worldAccel: SIMD3(0, 0, d * 2 * .pi / (T * T) * sin(2 * .pi * s / T)), dt: dt); s += dt }
    s = 0
    while s < 1.5 { t.ingest(worldAccel: .zero, dt: dt); s += dt }
}

private func examples(_ n: Int, noise: Double, seed: UInt64) -> [HunchExample] {
    var st = seed
    func r() -> Double { st = st &* 6364136223846793005 &+ 1442695040888963407; return Double(st >> 11) / Double(1 << 53) - 0.5 }
    return (0..<n).map { i in
        let h = i % 2 == 0
        var f = [Double](repeating: 0, count: HunchFeature.allCases.count)
        f[HunchFeature.meanForwardCM.rawValue] = (h ? 4 : 0.5) + noise * r()
        f[HunchFeature.meanPitch.rawValue] = (h ? -3 : 2) + noise * r()
        f[HunchFeature.chinPokeFraction.rawValue] = (h ? 0.8 : 0.1) + noise * 0.1 * r()
        for j in f.indices where f[j] == 0 { f[j] = r() }
        return HunchExample(features: f, hunched: h, date: Date().addingTimeInterval(Double(i) * 60))
    }
}

func deskAndModelTests() {
    print("Standing desk & hunch model performance")

    test("standing up and sitting down are detected from head height") {
        var tracker = RelativePositionTracker(), d = DeskModeDetector()
        func settle() -> Bool { d.update(heightCM: tracker.upCM, moving: tracker.moving) }
        rise(&tracker, 0)
        expect(!settle() && d.mode == .sitting)
        rise(&tracker, 0.5)
        expect(settle() && d.mode == .standing, "stood up (height \(tracker.upCM) cm)")
        rise(&tracker, -0.5)
        expect(settle() && d.mode == .sitting, "sat down (height \(tracker.upCM) cm)")
    }

    test("leaning and shuffling don't count as standing up") {
        var d = DeskModeDetector()
        for h in stride(from: 0.0, through: 10, by: 1) { _ = d.update(heightCM: h, moving: false) }   // 10 cm shift
        expect(d.mode == .sitting)
        // Slow drift of 40 cm over a long session is absorbed instead of triggering.
        var h = 0.0
        for _ in 0..<4000 { h += 0.01; _ = d.update(heightCM: h, moving: false) }
        expect(d.mode == .sitting, "slow drift must not flip the mode")
    }

    test("it never decides mid-movement, and can be corrected by hand") {
        var d = DeskModeDetector()
        expect(!d.update(heightCM: 60, moving: true) && d.mode == .sitting)
        d.set(.standing, heightCM: 60)
        expect(d.mode == .standing)
        expect(!d.update(heightCM: 58, moving: false) && d.mode == .standing)
        expect(d.update(heightCM: 10, moving: false) && d.mode == .sitting)
    }

    test("sitting and standing keep separate calibrations") {
        let sit = HeadCalibration(neutralGravity: SIMD3(0, 0, -1), forward: SIMD3(0, 1, 0), leverArm: SIMD3(0, 0, 0.09),
                                  leverFitted: false, earbud: .left, deskMode: .sitting)
        var stand = sit
        stand.neutralGravity = simd_normalize(SIMD3(0, 0.2, -1))
        stand.deskMode = .standing
        sit.save(); stand.save()
        expect(HeadCalibration.load(for: .left, mode: .sitting) == sit)
        expect(HeadCalibration.load(for: .left, mode: .standing) == stand)
        expect(HeadCalibration.load(for: .left) == sit, "default lookup is the sitting one (older saves)")
        for k in [HeadCalibration.key(.left, .sitting), HeadCalibration.key(.left, .standing)] { UserDefaults.standard.removeObject(forKey: k) }
    }

    test("held-out accuracy is honest: high on clear data, lower on noisy data") {
        guard let clean = HunchTrainer.train(examples(60, noise: 0.5, seed: 1))?.evaluation,
              let noisy = HunchTrainer.train(examples(60, noise: 12, seed: 2))?.evaluation else { return expect(false, "evaluation") }
        expect(clean.balancedAccuracy >= 0.9, "clean \(clean.balancedAccuracy)")
        expect(noisy.balancedAccuracy < clean.balancedAccuracy, "noisy \(noisy.balancedAccuracy) should be lower than clean \(clean.balancedAccuracy)")
        expect(clean.catchRate >= 0.85 && clean.falseAlarmRate <= 0.15)
        expect(clean.tested == 60)
        expect(HunchTrainer.train(examples(8, noise: 0.5, seed: 3)) == nil, "too few answers to judge")
    }

    test("the model's guess is recorded before each answer, for the live track record") {
        let defaults = UserDefaults(suiteName: "posture.tests.report")!
        defaults.removePersistentDomain(forName: "posture.tests.report")
        var learner = HunchLearner(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("posture-report-\(UUID().uuidString).json"), defaults: defaults)
        let ex = examples(40, noise: 0.5, seed: 4)
        for e in ex { learner.add(features: e.features, hunched: e.hunched, date: e.date) }
        expect(learner.examples.first?.predicted == nil, "no model yet for the first answers")
        expect(learner.examples.last?.predicted != nil, "later answers record the model's prior guess")
        guard let a = learner.recentAgreement() else { return expect(false, "agreement") }
        expect(a.total > 0 && Double(a.agreed) / Double(a.total) >= 0.8, "agreed \(a.agreed)/\(a.total)")
        let report = learner.report
        expect(report.personalized && report.evaluation != nil && report.hunchedAnswers == 20 && report.fineAnswers == 20)
        expect(report.signals.contains("head further forward") || report.signals.contains("chin tipped up")
               || report.signals.contains("chin-poke pattern"), "signals \(report.signals)")
        defaults.removePersistentDomain(forName: "posture.tests.report")
    }
}
