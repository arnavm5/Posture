import Foundation

private struct Rand {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    mutating func normal() -> Double { (next() + next() + next() + next() - 2) * 1.2 }
}

/// Head trace where you sit tall, then (if hunched) creep forward with the chin level over two minutes.
private func trace(hunched: Bool, seconds: Int = 400, rng: inout Rand) -> [PostureReading] {
    (0..<seconds).map { t in
        let creep = hunched ? min(1, Double(max(0, t - (seconds - 150))) / 120) : 0
        return PostureReading(tilt: 0, pitch: 2 + rng.normal() * 1.5 - 3 * creep, roll: rng.normal(),
                              forwardCM: 0.5 + rng.normal() * 0.8 + 3.5 * creep, dropCM: rng.normal() * 0.6 + 2 * creep)
    }
}

func hunchModelTests() {
    print("Hunch model (trees, selection, thresholds, storage)")

    test("boosted trees learn a combination pattern a linear model can't") {
        // Hunched exactly when forward AND chin-up, or when neither (an XOR-style interaction).
        var r = Rand(s: 11)
        var x: [[Double]] = [], y: [Double] = []
        for _ in 0..<400 {
            let a = r.next() * 2 - 1, b = r.next() * 2 - 1
            x.append([a, b, r.next()]); y.append((a > 0) == (b > 0) ? 1 : 0)
        }
        let w = [Double](repeating: 1, count: x.count)
        let trees = BoostedTrees.train(x: Array(x[0..<300]), y: Array(y[0..<300]), w: Array(w[0..<300]))
        let linear = HunchModel.fit(x: Array(x[0..<300]), y: Array(y[0..<300]), w: Array(w[0..<300]))
        let test = Array(zip(x[300...], y[300...]))
        let treeAcc = Double(test.filter { (trees.probability($0.0) > 0.5) == ($0.1 == 1) }.count) / Double(test.count)
        let linAcc = Double(test.filter { (linear.probability($0.0) > 0.5) == ($0.1 == 1) }.count) / Double(test.count)
        expect(treeAcc >= 0.9, "trees \(treeAcc)")
        expect(linAcc <= 0.7, "linear \(linAcc) (can't represent it)")
    }

    test("trees handle missing signals (older answers) with a learned default branch") {
        var r = Rand(s: 5)
        var x: [[Double]] = [], y: [Double] = []
        for i in 0..<300 {
            let label = i % 2 == 0
            // Older rows: only `a` is known (and informative). Newer rows: `b` is known and carries the signal.
            let a = i < 150 ? (label ? 1.0 : -1.0) + r.normal() * 0.4 : r.normal()
            let b = i < 150 ? Double.nan : (label ? 2.0 : -2.0) + r.normal() * 0.3
            x.append([a, b]); y.append(label ? 1 : 0)
        }
        let t = BoostedTrees.train(x: x, y: y, w: [Double](repeating: 1, count: x.count))
        expect(t.probability([1.2, .nan]) > 0.7 && t.probability([-1.2, .nan]) < 0.3, "uses a when b is missing")
        expect(t.probability([0.3, 2.2]) > 0.7 && t.probability([0.3, -2.2]) < 0.3,
               "uses b when present (\(t.probability([0.3, 2.2])) vs \(t.probability([0.3, -2.2])))")
    }

    test("the trainer keeps the simpler model unless trees are clearly better") {
        // Linear problem: logistic regression should win or tie (and then be preferred).
        var r = Rand(s: 3)
        let linear: [HunchExample] = (0..<80).map { i in
            var f = (0..<HunchFeatureSet.legacyCount).map { _ in r.normal() }
            let h = i % 2 == 0
            f[HunchFeature.meanForwardCM.rawValue] += h ? 1.5 : -1.5
            return HunchExample(features: f, hunched: h, date: Date().addingTimeInterval(Double(i) * 60))
        }
        guard let c1 = HunchTrainer.train(linear) else { return expect(false, "train") }
        expect(c1.kind == .logistic, "linear data → logistic (lr \(c1.logisticScore), trees \(c1.treesScore ?? -1))")
        // Interaction problem: trees should be chosen.
        let xor: [HunchExample] = (0..<160).map { i in
            var f = (0..<HunchFeatureSet.legacyCount).map { _ in r.normal() * 0.3 }
            let a = r.next() * 2 - 1, b = r.next() * 2 - 1
            f[HunchFeature.meanForwardCM.rawValue] = a * 4
            f[HunchFeature.meanPitch.rawValue] = b * 10
            return HunchExample(features: f, hunched: (a > 0) == (b > 0), date: Date().addingTimeInterval(Double(i) * 60))
        }
        guard let c2 = HunchTrainer.train(xor) else { return expect(false, "train") }
        expect(c2.kind == .boostedTrees, "interaction data → trees (lr \(c2.logisticScore), trees \(c2.treesScore ?? -1))")
        expect(c2.evaluation.balancedAccuracy > 0.8, "held-out \(c2.evaluation.balancedAccuracy)")
    }

    test("the cutoff is tuned instead of fixed at 50%") {
        // Probabilities that are systematically low: 0.5 would miss most hunches.
        var r = Rand(s: 9)
        let pairs: [(Double, Bool)] = (0..<200).map { i in
            let h = i % 2 == 0
            return ((h ? 0.38 : 0.18) + r.next() * 0.1, h)
        }
        guard let best = HunchTrainer.bestThreshold(pairs.map { Optional($0.0) }, pairs.map(\.1)) else { return expect(false, "threshold") }
        let fixed = HunchTrainer.evaluate(pairs, threshold: 0.5)
        expect(best.threshold < 0.45, "tuned threshold \(best.threshold)")
        expect(best.eval.balancedAccuracy > fixed.balancedAccuracy + 0.3, "tuned \(best.eval.balancedAccuracy) vs fixed \(fixed.balancedAccuracy)")
    }

    test("head history is stored compactly and restored accurately") {
        var r = Rand(s: 2)
        let t = trace(hunched: true, rng: &r)
        let back = HunchFeatureSet.decode(HunchFeatureSet.encode(t))
        expect(back.count == t.count)
        let err = zip(t, back).map { max(abs($0.pitch - $1.pitch), abs($0.forwardCM - $1.forwardCM), abs($0.dropCM - $1.dropCM)) }.max() ?? 1
        expect(err <= 0.051, "max error \(err)")
        expect(HunchFeatureSet.encode(t).count == t.count * 8, "8 bytes per second")
    }

    test("a tap describes the moment before you started sitting up") {
        // 60 s hunched (chin poke), then the last 5 s sitting tall (you noticed and corrected, then tapped).
        let hunchedPart = (0..<60).map { _ in PostureReading(tilt: 0, pitch: -2, roll: 0, forwardCM: 4, dropCM: 3) }
        let correction = (0..<5).map { _ in PostureReading(tilt: 0, pitch: 2, roll: 0, forwardCM: 0, dropCM: 0) }
        let t = hunchedPart + correction
        let atTap = HunchFeatureSet.legacy(t)![HunchFeature.chinPokeFraction.rawValue]
        let beforeTap = HunchFeatureSet.legacy(Array(t.dropLast(5)))![HunchFeature.chinPokeFraction.rawValue]
        expect(beforeTap == 1, "window before the tap is all hunched (\(beforeTap))")
        expect(atTap < beforeTap, "window ending at the tap includes the correction (\(atTap))")
        let v = HunchFeatureSet.vector(trace: t, lead: 5, deskMode: .sitting)!
        expect(v.count == HunchFeatureSet.count && v[HunchFeatureSet.legacyCount + HunchExtra.forward10.rawValue] == 4)
    }

    test("answers saved by older versions are migrated, not lost") {
        let suite = "posture.tests.migrate"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let old = (0..<30).map { i in HunchExample(features: [Double](repeating: Double(i % 2), count: 8), hunched: i % 2 == 0, date: Date()) }
        defaults.set(try! JSONEncoder().encode(old), forKey: "hunchExamples")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("posture-migrate-\(UUID().uuidString).json")
        let learner = HunchLearner(fileURL: file, defaults: defaults)
        expect(learner.examples.count == 30, "all old answers kept")
        expect(FileManager.default.fileExists(atPath: file.path), "moved to the answers file")
        expect(defaults.data(forKey: "hunchExamples") == nil, "old copy removed only after a successful save")
        expect(HunchLearner(fileURL: file, defaults: defaults).examples.count == 30)
        try? FileManager.default.removeItem(at: file)
        defaults.removePersistentDomain(forName: suite)
    }

    test("end to end: answers with head history train a model that catches a slow creep") {
        var r = Rand(s: 21)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("posture-e2e-\(UUID().uuidString).json")
        var learner = HunchLearner(fileURL: file, defaults: UserDefaults(suiteName: "posture.tests.e2e")!)
        let start = Date()
        for i in 0..<80 {
            let h = i % 2 == 0
            learner.add(trace: trace(hunched: h, rng: &r), lead: 0, hunched: h, deskMode: .sitting,
                        date: start.addingTimeInterval(Double(i) * 120))
        }
        learner.retrain()
        guard let c = learner.classifier else { return expect(false, "trained") }
        expect(c.withHistoryCount == 80)
        expect(c.evaluation.balancedAccuracy >= 0.85, "held-out \(c.evaluation.balancedAccuracy) using \(c.kind.label)")
        var d = HunchDetector()
        for reading in trace(hunched: true, rng: &r) { d.add(reading, model: c) }
        expect(d.isHunched, "a fresh creep is flagged (p = \(d.lastProbability ?? -1), cutoff \(c.threshold))")
        var calm = HunchDetector()
        for reading in trace(hunched: false, rng: &r) { calm.add(reading, model: c) }
        expect(!calm.isHunched, "sitting tall isn't")
        try? FileManager.default.removeItem(at: file)
    }
}

func hunchDataQualityTests() {
    print("Hunch data quality")

    test("rapid repeat answers count as one moment") {
        let t0 = Date()
        var ex: [HunchExample] = []
        for i in 0..<50 { ex.append(HunchExample(features: [Double](repeating: 1, count: 8), hunched: true, date: t0.addingTimeInterval(Double(i)))) }
        for i in 0..<5 { ex.append(HunchExample(features: [Double](repeating: 0, count: 8), hunched: false, date: t0.addingTimeInterval(600 + Double(i) * 300))) }
        expect(HunchTrainer.distinctMoments(ex) == 6, "50 taps in 50 s = 1 moment, plus 5 separate ones (got \(HunchTrainer.distinctMoments(ex)))")
        let rows = HunchTrainer.rows(ex)
        let hunchedWeight = rows.filter { $0.y == 1 }.reduce(0) { $0 + $1.w }
        let fineWeight = rows.filter { $0.y == 0 }.reduce(0) { $0 + $1.w }
        expect(abs(hunchedWeight - fineWeight) < 1e-9, "classes balanced by moments, not by tap count")
        expect(rows.filter { $0.y == 1 }.map(\.w).max()! < rows.filter { $0.y == 0 }.map(\.w).min()!,
               "each of the 50 repeat taps weighs less than one separate answer")
    }

    test("tapping again within 10 s replaces your last answer") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("posture-replace-\(UUID().uuidString).json")
        var learner = HunchLearner(fileURL: file, defaults: UserDefaults(suiteName: "posture.tests.replace")!)
        let tr = (0..<60).map { _ in PostureReading(tilt: 0, pitch: 0, roll: 0, forwardCM: 3, dropCM: 1) }
        let t0 = Date()
        expect(!learner.add(trace: tr, lead: 5, hunched: true, deskMode: .sitting, date: t0))
        expect(learner.add(trace: tr, lead: 5, hunched: false, deskMode: .sitting, date: t0.addingTimeInterval(4)), "correction replaces")
        expect(learner.examples.count == 1 && learner.examples[0].hunched == false)
        expect(!learner.add(trace: tr, lead: 5, hunched: true, deskMode: .sitting, date: t0.addingTimeInterval(30)), "later tap adds")
        expect(learner.examples.count == 2)
        try? FileManager.default.removeItem(at: file)
    }
}
