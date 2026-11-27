import Foundation

/// One second of head data.
private func reading(pitch: Double = 0, roll: Double = 0, forward: Double = 0, drop: Double = 0) -> PostureReading {
    PostureReading(tilt: abs(pitch), pitch: pitch, roll: roll, forwardCM: forward, dropCM: drop)
}

private func feed(_ d: inout HunchDetector, _ r: PostureReading, seconds: Int, model: HunchClassifier? = nil) {
    for _ in 0..<seconds { d.add(r, model: model) }
}

/// Synthetic labelled moments: "hunched" = head forward/down with chin level-or-up; "fine" = near neutral,
/// including looking down at the keyboard.
private func examples(count: Int, seed: UInt64 = 3) -> [HunchExample] {
    var s = seed
    func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    var out: [HunchExample] = []
    for i in 0..<count {
        let hunched = i % 2 == 0
        var d = HunchDetector()
        for _ in 0..<40 {
            let r = hunched
                ? reading(pitch: -4 + 6 * rnd(), roll: 3 * rnd(), forward: 3 + 3 * rnd(), drop: 2 + 3 * rnd())
                : (rnd() < 0.3 ? reading(pitch: 18 + 8 * rnd(), forward: 1, drop: 0.5)       // glancing down
                               : reading(pitch: 2 * rnd() - 1, roll: 2 * rnd(), forward: rnd(), drop: rnd()))
            d.add(r, model: nil)
        }
        out.append(HunchExample(features: d.legacyFeatures()!, hunched: hunched, date: Date().addingTimeInterval(Double(i) * 60)))
    }
    return out
}

func hunchTests() {
    print("Hunch detection & learning")

    test("sitting tall is never flagged") {
        var d = HunchDetector()
        feed(&d, reading(), seconds: 600)
        expect(!d.isHunched)
    }

    test("chin-poke pattern (head forward, chin level) is flagged after a minute") {
        var d = HunchDetector()
        feed(&d, reading(), seconds: 60)
        feed(&d, reading(pitch: -2, forward: 4, drop: 3), seconds: 60)
        expect(!d.isHunched, "not before a minute (p = \(d.hunchProbability))")
        feed(&d, reading(pitch: -2, forward: 4, drop: 3), seconds: 50)
        expect(d.isHunched, "flagged after 110 s of the pattern (p = \(d.hunchProbability))")
    }

    test("looking down at the keyboard is not a hunch") {
        var d = HunchDetector()
        feed(&d, reading(pitch: 25, forward: 5, drop: 2), seconds: 400)
        expect(!d.isHunched)
    }

    test("slow chin-up drift over minutes counts (the creep AirPods can't feel as movement)") {
        var d = HunchDetector()
        for i in 0..<400 { d.add(reading(pitch: -Double(i) / 400 * 10), model: nil) }   // 0° → −10° over ~7 min
        expect(d.isHunched, "drift \(d.legacyFeatures()?[HunchFeature.pitchDrift.rawValue] ?? 0)")
    }

    test("brief breaks don't reset it, a real break does") {
        var d = HunchDetector()
        feed(&d, reading(pitch: -2, forward: 4), seconds: 120)
        expect(d.isHunched)
        feed(&d, reading(), seconds: 5)
        feed(&d, reading(pitch: -2, forward: 4), seconds: 1)
        expect(d.isHunched, "5 s break shouldn't reset")
        feed(&d, reading(), seconds: 45)
        expect(!d.isHunched, "sitting tall for 45 s resets")
    }

    test("model needs enough answers of both kinds") {
        expect(HunchModel.train(examples(count: 10)) == nil, "too few")
        let allHunched = examples(count: 30).map { HunchExample(features: $0.features, hunched: true, date: $0.date) }
        expect(HunchModel.train(allHunched) == nil, "one class only")
        expect(HunchModel.train(examples(count: 30)) != nil)
    }

    test("model learns hunched vs fine from labelled moments") {
        guard let model = HunchModel.train(examples(count: 60)) else { return expect(false, "training failed") }
        expect(model.trainingAccuracy >= 0.9, "accuracy \(model.trainingAccuracy)")
        let unseen = examples(count: 40, seed: 99)
        let correct = unseen.filter { (model.probability($0.features) > 0.5) == $0.hunched }.count
        expect(Double(correct) / 40 >= 0.85, "held-out accuracy \(correct)/40")
    }

    test("a personal model overrides the rules once trained") {
        // This person's "hunch" is a sideways lean, which the built-in rules don't know about.
        var ex: [HunchExample] = []
        for i in 0..<40 {
            var d = HunchDetector()
            let hunched = i % 2 == 0
            feed(&d, reading(roll: hunched ? 10 + Double(i % 5) : Double(i % 3)), seconds: 35)
            ex.append(HunchExample(features: d.legacyFeatures()!, hunched: hunched, date: Date().addingTimeInterval(Double(i) * 60)))
        }
        guard let model = HunchTrainer.train(ex) else { return expect(false, "training failed") }
        var d = HunchDetector()
        feed(&d, reading(roll: 12), seconds: 120, model: model)
        expect(d.isHunched, "learned pattern flagged (p = \(d.lastProbability ?? -1))")
        var calm = HunchDetector()
        feed(&calm, reading(roll: 1), seconds: 120, model: model)
        expect(!calm.isHunched)
    }

    test("answers are saved, capped, and summarised") {
        let defaults = UserDefaults(suiteName: "posture.tests.hunch")!
        defaults.removePersistentDomain(forName: "posture.tests.hunch")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("posture-test-\(UUID().uuidString).json")
        var learner = HunchLearner(fileURL: file, defaults: defaults)
        expect(learner.summary.contains("built-in rules"))
        for e in examples(count: 24) { learner.add(features: e.features, hunched: e.hunched, date: e.date) }
        expect(learner.classifier != nil, "model trained after 24 answers")
        expect(learner.summary.contains("Personalized"))
        let reloaded = HunchLearner(fileURL: file, defaults: defaults, trainNow: true)
        expect(reloaded.examples.count == 24 && reloaded.classifier != nil, "persists across launches")
        for e in examples(count: 640) { learner.add(features: e.features, hunched: e.hunched, date: e.date.addingTimeInterval(86_400)) }
        expect(learner.examples.count == HunchLearner.maxExamples, "capped at \(HunchLearner.maxExamples)")
        learner.forgetAll()
        expect(learner.examples.isEmpty && learner.classifier == nil)
        expect(!FileManager.default.fileExists(atPath: file.path), "file deleted")
        defaults.removePersistentDomain(forName: "posture.tests.hunch")
    }
}
