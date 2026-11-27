import Foundation

private func reading(pitch: Double = 0, roll: Double = 0, forward: Double = 0, drop: Double = 0) -> PostureReading {
    PostureReading(tilt: abs(pitch), pitch: pitch, roll: roll, forwardCM: forward, dropCM: drop)
}

/// Head position for a given trunk lean and neck bend (the same geometry the filter inverts).
private func head(trunk: Double, neck: Double, sink: Double = 0) -> PostureReading {
    let t: Double = trunk * .pi / 180
    let p: Double = (trunk + neck) * .pi / 180
    let r: Double = BodyPoseFilter.trunkRadius * 100
    let l: Double = BodyPoseFilter.neckLever * 100
    let forward: Double = r * sin(t) + l * sin(p)
    let drop: Double = r * (1 - cos(t)) + l * (1 - cos(p)) + sink
    return reading(pitch: trunk + neck, forward: forward, drop: drop)
}

private func settle(_ r: PostureReading, seconds: Int = 120) -> BodyPose {
    var f = BodyPoseFilter()
    var pose = BodyPose()
    for _ in 0..<seconds { pose = f.add(r) }
    return pose
}

func bodyModelTests() {
    print("Body model")

    test("looking down is the neck bending, not the trunk") {
        let pose = settle(head(trunk: 0, neck: 25))
        expectNear(pose.trunkDeg, 0, tolerance: 1, "trunk")
        expectNear(pose.neckDeg, 25, tolerance: 1, "neck")
    }

    test("chin poke is the trunk forward with the neck bent back") {
        let pose = settle(head(trunk: 8, neck: -10, sink: 2))
        expectNear(pose.trunkDeg, 8, tolerance: 1, "trunk")
        expectNear(pose.neckDeg, -10, tolerance: 1, "neck")
        expectNear(pose.sinkCM, 2, tolerance: 0.5, "sink")
    }

    test("leaning in with the head following is all trunk") {
        let pose = settle(head(trunk: 10, neck: 0))
        expectNear(pose.trunkDeg, 10, tolerance: 1, "trunk")
        expectNear(pose.neckDeg, 0, tolerance: 1, "neck")
    }

    test("a quick lurch barely moves the trunk; a lasting shift does") {
        var f = BodyPoseFilter()
        for _ in 0..<120 { f.add(head(trunk: 0, neck: 0)) }
        for _ in 0..<2 { f.add(head(trunk: 12, neck: -12)) }
        expect(f.pose.trunkDeg < 3, "after a 2 s lurch: \(f.pose.trunkDeg)°")
        for _ in 0..<60 { f.add(head(trunk: 12, neck: -12)) }
        expectNear(f.pose.trunkDeg, 12, tolerance: 1.5, "after a minute")
    }

    test("a glance down while hunched keeps the trunk where it was") {
        var f = BodyPoseFilter()
        for _ in 0..<120 { f.add(head(trunk: 8, neck: -8)) }
        for _ in 0..<3 { f.add(head(trunk: 8, neck: 20)) }
        expectNear(f.pose.trunkDeg, 8, tolerance: 1.5, "trunk")
        expect(f.pose.neckDeg > 15, "neck took the glance: \(f.pose.neckDeg)°")
    }

    test("body features separate a hunch from looking down") {
        let hunched = [PostureReading](repeating: head(trunk: 8, neck: -9, sink: 1.5), count: 200)
        let looking = [PostureReading](repeating: head(trunk: 0, neck: 25), count: 200)
        let fh = HunchFeatureSet.vector(trace: hunched, lead: 0, deskMode: .sitting)!
        let fl = HunchFeatureSet.vector(trace: looking, lead: 0, deskMode: .sitting)!
        func x(_ f: [Double], _ e: HunchExtra) -> Double { f[HunchFeatureSet.legacyCount + e.rawValue] }
        expect(x(fh, .trunk30) > 6 && abs(x(fl, .trunk30)) < 1, "trunk \(x(fh, .trunk30)) vs \(x(fl, .trunk30))")
        expect(x(fh, .neck30) < -6 && x(fl, .neck30) > 20, "neck \(x(fh, .neck30)) vs \(x(fl, .neck30))")
        expect(x(fh, .compensation120) > 0.9 && x(fl, .compensation120) == 0, "compensation")
        expect(HunchTrainer.words.allSatisfy { $0.contains("|") }, "every feature has a description")
    }
}

func hunchStateTests() {
    print("Hunch state filter")

    test("ordinary evidence flags after secondsToFlag") {
        for seconds in [30, 60, 120] {
            var s = HunchStateFilter(secondsToFlag: seconds)
            var n = 0
            while !s.isHunched && n < 1000 { s.add(evidence: 1); n += 1 }
            expect(abs(n - seconds) <= 1, "secondsToFlag \(seconds): flagged after \(n) s")
        }
    }

    test("strong evidence flags sooner than borderline evidence") {
        var strong = HunchStateFilter(), weak = HunchStateFilter()
        var ns = 0, nw = 0
        while !strong.isHunched && ns < 1000 { strong.add(evidence: HunchStateFilter.maxStrength); ns += 1 }
        while !weak.isHunched && nw < 1000 { weak.add(evidence: 1); nw += 1 }
        expect(ns < nw, "strong \(ns) s vs ordinary \(nw) s")
    }

    test("a few seconds of contrary evidence don't flip it either way") {
        var s = HunchStateFilter()
        for _ in 0..<300 { s.add(evidence: 1) }
        for _ in 0..<5 { s.add(evidence: -1) }
        expect(s.isHunched, "5 s upright after a long hunch (p = \(s.probability))")
        var calm = HunchStateFilter()
        for _ in 0..<300 { calm.add(evidence: -1) }
        for _ in 0..<10 { calm.add(evidence: 1) }
        expect(!calm.isHunched && calm.probability < 0.1, "10 s hunchy after sitting tall (p = \(calm.probability))")
    }

    test("sitting tall clears a long hunch within half a minute") {
        var s = HunchStateFilter()
        for _ in 0..<1200 { s.add(evidence: 1) }
        var n = 0
        while s.isHunched && n < 1000 { s.add(evidence: -1); n += 1 }
        expect(n <= 30, "cleared after \(n) s")
        expect(n >= 5, "not instantly (\(n) s)")
    }

    test("model evidence: unsure near the cutoff, graded beyond it") {
        expect(HunchStateFilter.modelEvidence(probability: 0.55, threshold: 0.5) == nil)
        expectNear(HunchStateFilter.modelEvidence(probability: 0.6, threshold: 0.5) ?? 0, 1, tolerance: 0.01, "band edge")
        expectNear(HunchStateFilter.modelEvidence(probability: 0.99, threshold: 0.5) ?? 0, HunchStateFilter.maxStrength,
                   tolerance: 0.01, "capped")
        expect((HunchStateFilter.modelEvidence(probability: 0.1, threshold: 0.5) ?? 0) < -1, "strongly fine")
        expect((HunchStateFilter.modelEvidence(probability: 0.35, threshold: 0.25) ?? 0) > 0, "uses the tuned cutoff")
    }
}
