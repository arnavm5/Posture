import Foundation

// MARK: - Logistic regression

/// Logistic regression on standardised features: a weighted sum of signals, squashed to a probability.
/// Simple and data-efficient, but it can only learn "more of X → more likely hunched".
struct HunchModel: Codable, Equatable {
    var weights: [Double]          // per feature
    var bias: Double
    var means: [Double]
    var stds: [Double]
    var trainingAccuracy: Double
    var exampleCount: Int

    static let minExamples = 20
    static let minPerClass = 5

    func probability(_ f: [Double]) -> Double {
        var z = bias
        for i in 0..<min(f.count, weights.count) where !f[i].isNaN { z += weights[i] * (f[i] - means[i]) / stds[i] }
        return 1 / (1 + exp(-z))
    }

    /// Fits on a feature matrix with per-row weights (y: 1 = hunched).
    static func fit(x: [[Double]], y: [Double], w: [Double], iterations: Int = 600, learningRate: Double = 0.3, l2: Double = 0.02) -> HunchModel {
        let d = x.first?.count ?? 0
        let wsum = max(w.reduce(0, +), 1e-9)
        var means = [Double](repeating: 0, count: d), stds = [Double](repeating: 1, count: d)
        for j in 0..<d {
            means[j] = zip(x, w).reduce(0) { $0 + $1.0[j] * $1.1 } / wsum
            let v = zip(x, w).reduce(0) { $0 + ($1.0[j] - means[j]) * ($1.0[j] - means[j]) * $1.1 } / wsum
            stds[j] = max(v.squareRoot(), 1e-3)
        }
        let xs = x.map { r in (0..<d).map { (r[$0] - means[$0]) / stds[$0] } }
        var wt = [Double](repeating: 0, count: d), b = 0.0
        for _ in 0..<iterations {
            var gw = [Double](repeating: 0, count: d), gb = 0.0
            for i in xs.indices {
                var z = b
                for j in 0..<d { z += wt[j] * xs[i][j] }
                let err = (1 / (1 + exp(-z)) - y[i]) * w[i]
                for j in 0..<d { gw[j] += err * xs[i][j] }
                gb += err
            }
            for j in 0..<d { wt[j] -= learningRate * (gw[j] / wsum + l2 * wt[j]) }
            b -= learningRate * gb / wsum
        }
        var m = HunchModel(weights: wt, bias: b, means: means, stds: stds, trainingAccuracy: 0, exampleCount: x.count)
        m.trainingAccuracy = Double(zip(x, y).filter { (m.probability($0.0) > 0.5) == ($0.1 == 1) }.count) / Double(max(1, x.count))
        return m
    }

    /// Trains on the 8 summary features of the examples (class-balanced), or nil if there aren't enough.
    static func train(_ examples: [HunchExample]) -> HunchModel? {
        let pos = examples.filter(\.hunched).count, neg = examples.count - pos
        guard examples.count >= minExamples, pos >= minPerClass, neg >= minPerClass else { return nil }
        let n = Double(examples.count)
        let wPos = n / (2 * Double(pos)), wNeg = n / (2 * Double(neg))
        var m = fit(x: examples.map(\.features), y: examples.map { $0.hunched ? 1 : 0 },
                    w: examples.map { $0.hunched ? wPos : wNeg })
        m.exampleCount = examples.count
        return m
    }

    /// Confident enough that check-in questions can stop.
    var isConfident: Bool { exampleCount >= 40 && trainingAccuracy >= 0.85 }
}

// MARK: - Gradient-boosted decision trees

/// Gradient-boosted decision trees (logistic loss), the go-to method for this kind of small, tabular data.
///
/// Each tree asks a few yes/no questions ("is your head more than 3 cm forward?", "is your chin
/// tipped up?") and the trees are added up, each one correcting the mistakes of those before it.
/// Unlike logistic regression it learns *combinations* and *thresholds* ("forward AND chin up, but not
/// while looking down"). Missing values (signals older answers don't have) get a learned default branch.
struct BoostedTrees: Codable, Equatable {
    struct Node: Codable, Equatable {
        var feature: Int          // -1 = leaf
        var threshold: Double
        var missingGoesLeft: Bool
        var left: Int
        var right: Int
        var value: Double
    }
    var trees: [[Node]]
    var base: Double
    var learningRate: Double
    /// Total split gain per feature (feature importance).
    var gain: [Double]

    func margin(_ x: [Double]) -> Double {
        var s = base
        for t in trees {
            var i = 0
            while t[i].feature >= 0 {
                let v = x[t[i].feature]
                i = v.isNaN ? (t[i].missingGoesLeft ? t[i].left : t[i].right) : (v < t[i].threshold ? t[i].left : t[i].right)
            }
            s += learningRate * t[i].value
        }
        return s
    }

    func probability(_ x: [Double]) -> Double { 1 / (1 + exp(-margin(x))) }

    struct Params {
        var rounds = 150
        var depth = 3
        var learningRate = 0.08
        var lambda = 2.0              // L2 on leaf values
        var minChildWeight = 1.5
        var subsample = 0.8
        var colsample = 0.8
        var seed: UInt64 = 7
    }

    static func train(x: [[Double]], y: [Double], w: [Double], params p: Params = Params()) -> BoostedTrees {
        let n = x.count, d = x.first?.count ?? 0
        var rng = SplitMix(seed: p.seed)
        // Pre-sort each feature once (non-missing rows), remember the missing rows.
        var sorted = [[Int]](repeating: [], count: d), missing = [[Int]](repeating: [], count: d)
        for j in 0..<d {
            sorted[j] = (0..<n).filter { !x[$0][j].isNaN }.sorted { x[$0][j] < x[$1][j] }
            missing[j] = (0..<n).filter { x[$0][j].isNaN }
        }
        let wp = zip(y, w).reduce(0) { $0 + $1.0 * $1.1 }, wn = zip(y, w).reduce(0) { $0 + (1 - $1.0) * $1.1 }
        let base = log(max(wp, 1e-6) / max(wn, 1e-6))
        var F = [Double](repeating: base, count: n)
        var trees: [[Node]] = []
        var gain = [Double](repeating: 0, count: d)

        for _ in 0..<p.rounds {
            var g = [Double](repeating: 0, count: n), h = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let pr = 1 / (1 + exp(-F[i]))
                g[i] = (pr - y[i]) * w[i]
                h[i] = max(pr * (1 - pr), 1e-6) * w[i]
            }
            var inSample = [Bool](repeating: false, count: n)
            for i in 0..<n { inSample[i] = rng.next() < p.subsample }
            let features = (0..<d).filter { _ in rng.next() < p.colsample }
            var node = [Int](repeating: 0, count: n)          // which node each row is in (sampled rows)
            var tree = [Node(feature: -1, threshold: 0, missingGoesLeft: true, left: -1, right: -1, value: 0)]
            var frontier = [0]

            for _ in 0..<p.depth {
                var next: [Int] = []
                for nid in frontier {
                    var G = 0.0, H = 0.0
                    for i in 0..<n where inSample[i] && node[i] == nid { G += g[i]; H += h[i] }
                    tree[nid].value = -G / (H + p.lambda)
                    guard H >= 2 * p.minChildWeight else { continue }
                    let parentScore = G * G / (H + p.lambda)
                    var best = (gain: 1e-9, feature: -1, threshold: 0.0, missLeft: true)
                    for j in features {
                        var Gm = 0.0, Hm = 0.0
                        for i in missing[j] where inSample[i] && node[i] == nid { Gm += g[i]; Hm += h[i] }
                        var GL = 0.0, HL = 0.0
                        var prev: Double?
                        for i in sorted[j] where inSample[i] && node[i] == nid {
                            let v = x[i][j]
                            if let pv = prev, v > pv {
                                for missLeft in [true, false] {
                                    let gl = GL + (missLeft ? Gm : 0), hl = HL + (missLeft ? Hm : 0)
                                    let gr = G - gl, hr = H - hl
                                    guard hl >= p.minChildWeight, hr >= p.minChildWeight else { continue }
                                    let s = gl * gl / (hl + p.lambda) + gr * gr / (hr + p.lambda) - parentScore
                                    if s > best.gain { best = (s, j, (pv + v) / 2, missLeft) }
                                }
                            }
                            GL += g[i]; HL += h[i]; prev = v
                        }
                    }
                    guard best.feature >= 0 else { continue }
                    let l = tree.count, r = tree.count + 1
                    tree.append(Node(feature: -1, threshold: 0, missingGoesLeft: true, left: -1, right: -1, value: 0))
                    tree.append(Node(feature: -1, threshold: 0, missingGoesLeft: true, left: -1, right: -1, value: 0))
                    tree[nid].feature = best.feature
                    tree[nid].threshold = best.threshold
                    tree[nid].missingGoesLeft = best.missLeft
                    tree[nid].left = l
                    tree[nid].right = r
                    gain[best.feature] += best.gain
                    for i in 0..<n where inSample[i] && node[i] == nid {
                        let v = x[i][best.feature]
                        node[i] = v.isNaN ? (best.missLeft ? l : r) : (v < best.threshold ? l : r)
                    }
                    next += [l, r]
                }
                frontier = next
            }
            // Leaf values for the last level.
            for nid in frontier {
                var G = 0.0, H = 0.0
                for i in 0..<n where inSample[i] && node[i] == nid { G += g[i]; H += h[i] }
                tree[nid].value = -G / (H + p.lambda)
            }
            trees.append(tree)
            let model = BoostedTrees(trees: [tree], base: 0, learningRate: p.learningRate, gain: [])
            for i in 0..<n { F[i] += model.margin(x[i]) }
        }
        return BoostedTrees(trees: trees, base: base, learningRate: p.learningRate, gain: gain)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

// MARK: - The classifier the app uses

/// How well a model does on answers it did *not* learn from.
struct HunchEvaluation: Equatable, Codable {
    var accuracy: Double            // share of held-out answers it got right
    var catchRate: Double           // of the moments you said "hunched", how many it flagged
    var falseAlarmRate: Double      // of the moments you said "fine", how many it wrongly flagged
    var tested: Int
    /// Average of catch rate and (1 − false alarms): fair even if you gave more of one answer.
    var balancedAccuracy: Double { (catchRate + 1 - falseAlarmRate) / 2 }
}

struct HunchClassifier: Codable, Equatable {
    enum Kind: String, Codable { case logistic, boostedTrees
        var label: String { self == .logistic ? "Logistic regression" : "Gradient-boosted trees" }
    }
    var kind: Kind
    var logistic: HunchModel?         // uses the 8 summary features
    var trees: BoostedTrees?          // uses all features
    /// Probability above which it calls "hunched" (tuned on held-out answers, not fixed at 50%).
    var threshold: Double
    var evaluation: HunchEvaluation
    /// Held-out balanced accuracy of each candidate (how the choice was made).
    var logisticScore: Double
    var treesScore: Double?
    var exampleCount: Int
    var withHistoryCount: Int
    var distinctMoments: Int = 0
    var signals: [String]

    static let minMoments = 10
    static let minHeldOutScore = 0.6

    /// Only trusted over the built-in rules once it clearly beats chance on answers it didn't learn from.
    var isUsable: Bool { distinctMoments >= Self.minMoments && evaluation.balancedAccuracy >= Self.minHeldOutScore }

    /// Why it isn't used yet (nil when it is).
    var notUsedReason: String? {
        if distinctMoments < Self.minMoments {
            return "Your answers cover \(distinctMoments) distinct moment\(distinctMoments == 1 ? "" : "s"); it needs at least \(Self.minMoments) spread over time."
        }
        if evaluation.balancedAccuracy < Self.minHeldOutScore {
            return "On answers it didn't learn from it scores \(Int((evaluation.balancedAccuracy * 100).rounded()))%, not clearly better than chance, so the built-in rules stay in charge."
        }
        return nil
    }

    func probability(_ f: [Double]) -> Double {
        switch kind {
        case .logistic: return logistic?.probability(Array(f.prefix(HunchFeatureSet.legacyCount))) ?? 0.5
        case .boostedTrees: return trees?.probability(f) ?? 0.5
        }
    }

    var isConfident: Bool { isUsable && distinctMoments >= 40 && evaluation.balancedAccuracy >= 0.8 }
}

/// Builds training rows from answers, compares models fairly, and trains the winner.
enum HunchTrainer {
    struct Row { var x: [Double]; var y: Double; var w: Double; var example: Int; var isBase: Bool }

    /// Each answer becomes one row; answers with stored history also get two slightly earlier windows
    /// (5 and 10 s before), which teaches the model the pattern rather than one exact second.
    /// Answers less than this far apart describe (almost) the same 30 seconds of head data.
    static let sameMoment: TimeInterval = 20

    /// Groups answers into distinct moments: consecutive answers less than 20 s apart are one moment.
    static func momentIDs(_ examples: [HunchExample]) -> [Int] {
        let order = examples.indices.sorted { examples[$0].date < examples[$1].date }
        var id = [Int](repeating: 0, count: examples.count)
        var current = -1
        var last: Date?
        for i in order {
            if last == nil || examples[i].date.timeIntervalSince(last!) > sameMoment { current += 1 }
            id[i] = current
            last = examples[i].date
        }
        return id
    }

    static func distinctMoments(_ examples: [HunchExample]) -> Int { (momentIDs(examples).max() ?? -1) + 1 }

    static func rows(_ examples: [HunchExample]) -> [Row] {
        // Rapid repeat answers about the same moment share one vote, so 50 taps in a minute can't
        // outweigh answers given at different times.
        let moment = momentIDs(examples)
        var groupSize: [String: Int] = [:]
        for (i, e) in examples.enumerated() { groupSize["\(moment[i])-\(e.hunched)", default: 0] += 1 }
        let share = examples.enumerated().map { i, e in 1 / Double(groupSize["\(moment[i])-\(e.hunched)"]!) }
        let pos = zip(examples, share).filter { $0.0.hunched }.reduce(0) { $0 + $1.1 }
        let neg = zip(examples, share).filter { !$0.0.hunched }.reduce(0) { $0 + $1.1 }
        let n = pos + neg
        let wPos = pos > 0 ? n / (2 * pos) : 1, wNeg = neg > 0 ? n / (2 * neg) : 1
        var out: [Row] = []
        for (i, e) in examples.enumerated() {
            let cw = (e.hunched ? wPos : wNeg) * share[i]
            let y = e.hunched ? 1.0 : 0.0
            if let data = e.trace {
                let trace = HunchFeatureSet.decode(data)
                let base = e.lead ?? 0
                let vs = [base, base + 5, base + 10].compactMap { lead in
                    HunchFeatureSet.vector(trace: trace, lead: lead, deskMode: e.deskMode).map { (lead, $0) }
                }
                for (lead, v) in vs { out.append(Row(x: v, y: y, w: cw / Double(vs.count), example: i, isBase: lead == base)) }
                if vs.isEmpty { out.append(Row(x: HunchFeatureSet.legacyOnly(e.features), y: y, w: cw, example: i, isBase: true)) }
            } else {
                out.append(Row(x: HunchFeatureSet.legacyOnly(e.features), y: y, w: cw, example: i, isBase: true))
            }
        }
        return out
    }

    /// Trains and evaluates both models with time-blocked cross-validation, picks the better one, tunes
    /// its threshold, and retrains it on everything. Nil until there are enough answers of both kinds.
    static func train(_ examples: [HunchExample], folds: Int = 5) -> HunchClassifier? {
        let pos = examples.filter(\.hunched).count, neg = examples.count - pos
        guard examples.count >= HunchModel.minExamples, pos >= HunchModel.minPerClass, neg >= HunchModel.minPerClass
        else { return nil }
        let all = rows(examples)
        let fold = foldAssignment(examples, folds: folds)

        let useTrees = examples.count >= 40          // trees need a bit more data to beat a linear model
        var oofLogistic = [Double?](repeating: nil, count: examples.count)
        var oofTrees = [Double?](repeating: nil, count: examples.count)
        for k in 0..<folds {
            let train = all.filter { fold[$0.example] != k }, test = all.filter { fold[$0.example] == k && $0.isBase }
            guard Set(train.map(\.y)).count == 2, !test.isEmpty else { continue }
            let lr = fitLogistic(train)
            for r in test { oofLogistic[r.example] = lr.probability(Array(r.x.prefix(HunchFeatureSet.legacyCount))) }
            if useTrees {
                let bt = BoostedTrees.train(x: train.map(\.x), y: train.map(\.y), w: train.map(\.w))
                for r in test { oofTrees[r.example] = bt.probability(r.x) }
            }
        }
        let labels = examples.map(\.hunched)
        guard let lrBest = bestThreshold(oofLogistic, labels) else { return nil }
        let btBest = useTrees ? bestThreshold(oofTrees, labels) : nil

        // Prefer the simpler model unless the trees are clearly better on held-out answers.
        let kind: HunchClassifier.Kind = (btBest.map { $0.eval.balancedAccuracy > lrBest.eval.balancedAccuracy + 0.02 } ?? false)
            ? .boostedTrees : .logistic
        let chosen = kind == .boostedTrees ? btBest! : lrBest

        let finalLR = fitLogistic(all)
        let finalBT = kind == .boostedTrees ? BoostedTrees.train(x: all.map(\.x), y: all.map(\.y), w: all.map(\.w)) : nil
        var c = HunchClassifier(kind: kind, logistic: finalLR, trees: finalBT, threshold: chosen.threshold,
                                evaluation: chosen.eval, logisticScore: lrBest.eval.balancedAccuracy,
                                treesScore: btBest?.eval.balancedAccuracy, exampleCount: examples.count,
                                withHistoryCount: examples.filter(\.hasHistory).count,
                                distinctMoments: distinctMoments(examples), signals: [])
        c.signals = signals(for: c, rows: all)
        return c
    }

    /// Time-blocked folds by *moment*: answers close in time look alike, so they're held out together, and
    /// answers from the same moment (under 20 s apart) can never end up on both sides of the split.
    static func foldAssignment(_ examples: [HunchExample], folds: Int) -> [Int] {
        let moment = momentIDs(examples)
        let count = max(1, (moment.max() ?? 0) + 1)
        return moment.map { $0 * folds / count }
    }

    private static func fitLogistic(_ rows: [Row]) -> HunchModel {
        HunchModel.fit(x: rows.map { Array($0.x.prefix(HunchFeatureSet.legacyCount)) }, y: rows.map(\.y), w: rows.map(\.w))
    }

    /// Picks the probability cutoff that best balances catching hunches against false alarms.
    static func bestThreshold(_ probs: [Double?], _ labels: [Bool]) -> (threshold: Double, eval: HunchEvaluation)? {
        let pairs = zip(probs, labels).compactMap { p, y in p.map { ($0, y) } }
        guard pairs.count >= 10 else { return nil }
        var best: (Double, HunchEvaluation)?
        for t in stride(from: 0.2, through: 0.8, by: 0.02) {
            let e = evaluate(pairs, threshold: t)
            if best == nil || e.balancedAccuracy > best!.1.balancedAccuracy + 1e-9
                || (abs(e.balancedAccuracy - best!.1.balancedAccuracy) < 1e-9 && abs(t - 0.5) < abs(best!.0 - 0.5)) {
                best = (t, e)
            }
        }
        return best
    }

    static func evaluate(_ pairs: [(Double, Bool)], threshold: Double) -> HunchEvaluation {
        var tp = 0, fp = 0, tn = 0, fn = 0
        for (p, y) in pairs {
            switch (p > threshold, y) {
            case (true, true): tp += 1
            case (true, false): fp += 1
            case (false, false): tn += 1
            case (false, true): fn += 1
            }
        }
        let n = max(1, tp + fp + tn + fn)
        return HunchEvaluation(accuracy: Double(tp + tn) / Double(n),
                               catchRate: tp + fn > 0 ? Double(tp) / Double(tp + fn) : 0,
                               falseAlarmRate: fp + tn > 0 ? Double(fp) / Double(fp + tn) : 0, tested: n)
    }

    // MARK: What the model learned, in words

    static let words: [String] = {
        var w = [String](repeating: "", count: HunchFeatureSet.count)
        let legacy: [HunchFeature: String] = [
            .meanPitch: "head tipped down|chin tipped up", .meanSideTilt: "leaning to one side|head level side to side",
            .meanForwardCM: "head further forward|head further back", .meanDropCM: "head lower|head higher",
            .pitchSteadiness: "more head movement|holding very still",
            .pitchDrift: "head drifting down over minutes|chin drifting up over minutes",
            .lookingDownFraction: "looking down more|looking down less", .chinPokeFraction: "chin-poke pattern|no chin-poke pattern",
        ]
        for (f, s) in legacy { w[f.rawValue] = s }
        let extra: [HunchExtra: String] = [
            .pitch10: "head tipped down right now|chin up right now", .forward10: "head forward right now|head back right now",
            .drop10: "head lower right now|head higher right now",
            .pitch120: "head tipped down over 2 min|chin up over 2 min", .forward120: "head forward over 2 min|head back over 2 min",
            .drop120: "head lower over 2 min|head higher over 2 min",
            .forwardWobble30: "head position shifting around|head position steady",
            .dropWobble30: "head height shifting around|head height steady", .sideLean30: "leaning left|leaning right",
            .pitchTrend120: "head tipping down over the last 2 min|chin rising over the last 2 min",
            .forwardTrend120: "head creeping forward|head moving back", .dropTrend120: "head sinking|head rising",
            .pitchDrift15min: "head lower than 15 min ago|chin higher than 15 min ago",
            .pitchVsUsual: "head tipped down vs your usual|chin up vs your usual",
            .forwardVsUsual: "head further forward than your usual|head further back than your usual",
            .dropVsUsual: "head lower than your usual|head higher than your usual",
            .chinPoke120: "chin-poke pattern over 2 min|no chin-poke over 2 min",
            .lookingDown120: "looking down a lot|rarely looking down",
            .jitter30: "lots of small head movements|very little head movement",
            .pitchRange120: "head angle varying a lot|head angle fixed",
            .stillness120: "holding still for long stretches|moving often", .standing: "standing|sitting",
        ]
        for (f, s) in extra { w[HunchFeatureSet.legacyCount + f.rawValue] = s }
        return w
    }()

    /// Top signals, strongest first. Direction = whether the signal is higher or lower when you said "hunched".
    static func signals(for c: HunchClassifier, rows: [Row], count: Int = 4) -> [String] {
        let importance: [Double]
        switch c.kind {
        case .logistic: importance = (c.logistic?.weights ?? []).map(abs)
        case .boostedTrees: importance = c.trees?.gain ?? []
        }
        let total = max(importance.reduce(0, +), 1e-9)
        return importance.enumerated()
            .filter { $0.element / total > 0.04 }
            .sorted { $0.element > $1.element }
            .prefix(count)
            .compactMap { j, _ in
                let parts = words[j].split(separator: "|").map(String.init)
                guard parts.count == 2 else { return nil }
                let hv = rows.filter { $0.y == 1 && !$0.x[j].isNaN }.map { $0.x[j] }
                let fv = rows.filter { $0.y == 0 && !$0.x[j].isNaN }.map { $0.x[j] }
                guard !hv.isEmpty, !fv.isEmpty else { return nil }
                return HunchFeatureSet.mean(hv) >= HunchFeatureSet.mean(fv) ? parts[0] : parts[1]
            }
    }
}

// MARK: - Storage

/// Stores your labelled moments (with their head history) and the model trained from them.
struct HunchLearner {
    private(set) var examples: [HunchExample]
    private(set) var classifier: HunchClassifier?
    private let fileURL: URL
    static let maxExamples = 600
    private static let legacyKey = "hunchExamples"

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Posture", isDirectory: true)
        return dir.appendingPathComponent("hunch-answers.json")
    }

    /// Loads saved answers. Answers saved by older versions (in preferences) are migrated, not lost.
    init(fileURL: URL = HunchLearner.defaultURL, defaults: UserDefaults = .standard, trainNow: Bool = false) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([HunchExample].self, from: data) {
            examples = saved
        } else if let data = defaults.data(forKey: Self.legacyKey),
                  let saved = try? JSONDecoder().decode([HunchExample].self, from: data) {
            examples = saved
            if save() { defaults.removeObject(forKey: Self.legacyKey) }
        } else {
            examples = []
        }
        if trainNow { retrain() }
    }

    /// Records an answer. `trace` is the head history up to now; `lead` how many seconds before now it describes.
    /// A second tap within this many seconds replaces the previous answer (a correction or a repeat).
    static let replaceWithin: TimeInterval = 10

    /// - Returns: true if this replaced your previous answer (tapped again within 10 s).
    @discardableResult
    mutating func add(trace: [PostureReading], lead: Int, hunched: Bool, deskMode: DeskMode, date: Date = Date()) -> Bool {
        guard let legacy = HunchFeatureSet.legacy(Array(trace.dropLast(lead))) else { return false }
        var replaced = false
        if let last = examples.last, date.timeIntervalSince(last.date) < Self.replaceWithin {
            examples.removeLast()
            replaced = true
        }
        let full = HunchFeatureSet.vector(trace: trace, lead: lead, deskMode: deskMode)
        let predicted = full.flatMap { f in classifier.map { $0.probability(f) } }
        examples.append(HunchExample(features: legacy, hunched: hunched, date: date, predicted: predicted,
                                     predictedHunched: predicted.map { $0 > (classifier?.threshold ?? 0.5) },
                                     trace: HunchFeatureSet.encode(Array(trace.suffix(HunchFeatureSet.traceLength))),
                                     lead: lead, deskMode: deskMode))
        if examples.count > Self.maxExamples { examples.removeFirst(examples.count - Self.maxExamples) }
        save()
        return replaced
    }

    /// Answer from older versions / tests: summary features only.
    mutating func add(features: [Double], hunched: Bool, date: Date = Date()) {
        let p = classifier.map { $0.probability(HunchFeatureSet.legacyOnly(features)) }
        examples.append(HunchExample(features: features, hunched: hunched, date: date, predicted: p,
                                     predictedHunched: p.map { $0 > (classifier?.threshold ?? 0.5) }))
        if examples.count > Self.maxExamples { examples.removeFirst(examples.count - Self.maxExamples) }
        save()
        retrain()
    }

    /// Synchronous retrain (the app retrains in the background instead; see `setClassifier`).
    mutating func retrain() { classifier = HunchTrainer.train(examples) }

    mutating func setClassifier(_ c: HunchClassifier?) { classifier = c }

    mutating func forgetAll() {
        examples = []
        classifier = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(examples).write(to: fileURL, options: .atomic)
            return true
        } catch { return false }
    }

    var hunchedCount: Int { examples.filter(\.hunched).count }
    var fineCount: Int { examples.count - hunchedCount }

    /// Short status line for the UI.
    var summary: String {
        if let c = classifier, let why = c.notUsedReason {
            return "Using built-in rules. \(why)"
        }
        if let c = classifier {
            return "Personalized from \(c.exampleCount) answers · \(Int((c.evaluation.balancedAccuracy * 100).rounded()))% on held-out answers"
        }
        let needHunched = max(0, HunchModel.minPerClass - hunchedCount)
        let needFine = max(0, HunchModel.minPerClass - fineCount)
        let needTotal = max(0, HunchModel.minExamples - examples.count)
        if examples.isEmpty { return "Using built-in rules. Tell it when you're hunched to personalize." }
        var parts: [String] = []
        if needHunched > 0 { parts.append("\(needHunched) more \"hunched\"") }
        if needFine > 0 { parts.append("\(needFine) more \"fine\"") }
        if parts.isEmpty && needTotal > 0 { parts.append("\(needTotal) more answers") }
        return "Learning: \(examples.count) answers so far, needs \(parts.joined(separator: " and "))"
    }

    /// Of your last answers given while a model existed, how many it called correctly beforehand.
    func recentAgreement(last n: Int = 20) -> (agreed: Int, total: Int)? {
        let judged = examples.filter { $0.predicted != nil }.suffix(n)
        guard !judged.isEmpty else { return nil }
        return (judged.filter { ($0.predictedHunched ?? ($0.predicted! > 0.5)) == $0.hunched }.count, judged.count)
    }

    var report: HunchReport {
        HunchReport(hunchedAnswers: hunchedCount, fineAnswers: fineCount, personalized: classifier?.isUsable ?? false,
                    confident: classifier?.isConfident ?? false, evaluation: classifier?.evaluation,
                    recentAgreement: recentAgreement(), signals: classifier?.signals ?? [],
                    modelKind: classifier?.kind, logisticScore: classifier?.logisticScore,
                    treesScore: classifier?.treesScore, threshold: classifier?.threshold,
                    withHistory: examples.filter(\.hasHistory).count, distinctMoments: HunchTrainer.distinctMoments(examples),
                    notUsedReason: classifier?.notUsedReason)
    }
}

/// Everything the "Hunch Model" window shows.
struct HunchReport: Equatable {
    var hunchedAnswers = 0
    var fineAnswers = 0
    var personalized = false
    var confident = false
    var evaluation: HunchEvaluation?
    var recentAgreement: (agreed: Int, total: Int)?
    var signals: [String] = []
    var modelKind: HunchClassifier.Kind?
    var logisticScore: Double?
    var treesScore: Double?
    var threshold: Double?
    var withHistory = 0
    var distinctMoments = 0
    var notUsedReason: String?
    var training = false

    static func == (a: HunchReport, b: HunchReport) -> Bool {
        a.hunchedAnswers == b.hunchedAnswers && a.fineAnswers == b.fineAnswers && a.personalized == b.personalized
            && a.confident == b.confident && a.evaluation == b.evaluation && a.signals == b.signals
            && a.recentAgreement?.agreed == b.recentAgreement?.agreed && a.recentAgreement?.total == b.recentAgreement?.total
            && a.modelKind == b.modelKind && a.logisticScore == b.logisticScore && a.treesScore == b.treesScore
            && a.threshold == b.threshold && a.withHistory == b.withHistory && a.training == b.training
            && a.distinctMoments == b.distinctMoments && a.notUsedReason == b.notUsedReason
    }
}
