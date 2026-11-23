import Foundation

/// Detects hunched shoulders from AirPods head data alone.
///
/// AirPods can't see your shoulders, but hunching leaves a signature in how your head sits:
/// as the upper back rounds, the head moves forward/down while the chin stays level or tips *up*
/// to keep the eyes on the screen ("chin poke"). That's the opposite of looking down at a keyboard.
/// Hunching also creeps in, so slow trends over minutes are clues too: the head *angle* is measured
/// accurately however slowly it changes.
///
/// Two layers:
///  - **Rules** (work from day one): sustained chin-poke pattern, or a slow chin-up drift.
///  - **Your model** (`HunchClassifier`): once you've labelled enough moments, a model trained on
///    *your* answers takes over: gradient-boosted trees or logistic regression, whichever predicts
///    your held-out answers better. It falls back to the rules when it's unsure.
struct HunchDetector {
    /// How long the pattern must last before it counts as hunching.
    var secondsToFlag = 60
    /// Sitting or standing (a model input).
    var deskMode: DeskMode = .sitting

    private(set) var history: [PostureReading] = []      // 1 Hz, newest last
    private(set) var hunchySeconds = 0
    private var calmSeconds = 0
    private(set) var lastProbability: Double?            // model output, if a model is in use
    private(set) var lastThreshold = 0.5
    private(set) var lastRuleSaysHunch = false

    static let maxHistory = HunchFeatureSet.traceLength

    var isHunched: Bool { hunchySeconds >= secondsToFlag }

    /// Is this a good moment to ask "are you hunched?" (the answer would teach the model the most)?
    var isUncertain: Bool {
        guard let f = legacyFeatures() else { return false }
        if let p = lastProbability { return abs(p - lastThreshold) < 0.15 }
        let chinPoke = f[HunchFeature.chinPokeFraction.rawValue]
        return lastRuleSaysHunch || (0.3...0.7).contains(chinPoke)
    }

    mutating func reset() {
        history = []
        hunchySeconds = 0
        calmSeconds = 0
        lastProbability = nil
        lastRuleSaysHunch = false
    }

    /// Feed one reading per second. Returns whether you're currently flagged as hunched.
    @discardableResult
    mutating func add(_ r: PostureReading, model: HunchClassifier?) -> Bool {
        history.append(r)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        guard let legacy = legacyFeatures() else { return false }

        lastRuleSaysHunch = Self.ruleSaysHunch(legacy)
        var hunchy = lastRuleSaysHunch
        if let model, let f = features() {
            let p = model.probability(f)
            lastProbability = p
            lastThreshold = model.threshold
            if p > model.threshold + 0.1 { hunchy = true } else if p < model.threshold - 0.1 { hunchy = false }  // unsure: rules
        } else {
            lastProbability = nil
        }

        if hunchy {
            hunchySeconds += 1
            calmSeconds = 0
        } else {
            calmSeconds += 1
            if calmSeconds >= 10 { hunchySeconds = 0 }        // brief breaks don't reset it
        }
        return isHunched
    }

    /// Full model input for the moment `lead` seconds ago (nil until there's 30 s of data).
    func features(lead: Int = 0) -> [Double]? {
        HunchFeatureSet.vector(trace: history, lead: lead, deskMode: deskMode)
    }

    /// The original 8 summary features of the last 30 s (used by the rules).
    func legacyFeatures(lead: Int = 0) -> [Double]? {
        HunchFeatureSet.legacy(Array(history.dropLast(lead)))
    }

    /// Head-data history up to now, for storing with an answer.
    func trace() -> [PostureReading] { history }

    /// Head forward/down while the chin is level or up (not looking down).
    static func chinPoke(_ r: PostureReading) -> Bool {
        r.pitch < 8 && (r.forwardCM > 2.5 || r.dropCM > 2.5 || r.pitch < -6)
    }

    static func ruleSaysHunch(_ f: [Double]) -> Bool {
        let chinPoke = f[HunchFeature.chinPokeFraction.rawValue]
        let drift = f[HunchFeature.pitchDrift.rawValue]
        let meanPitch = f[HunchFeature.meanPitch.rawValue]
        let lookingDown = f[HunchFeature.lookingDownFraction.rawValue]
        return lookingDown < 0.5 && (chinPoke >= 0.7 || (drift <= -6 && meanPitch < 8))
    }
}

/// The original 8 summary features (kept so answers recorded before full history was stored still count).
enum HunchFeature: Int, CaseIterable {
    case meanPitch, meanSideTilt, meanForwardCM, meanDropCM, pitchSteadiness, pitchDrift, lookingDownFraction, chinPokeFraction
}

/// Extra signals computed from the stored head history (multi-scale, trends, vs. your own normal).
enum HunchExtra: Int, CaseIterable {
    case pitch10, forward10, drop10
    case pitch120, forward120, drop120
    case forwardWobble30, dropWobble30, sideLean30
    case pitchTrend120, forwardTrend120, dropTrend120
    case pitchDrift15min
    case pitchVsUsual, forwardVsUsual, dropVsUsual
    case chinPoke120, lookingDown120
    case jitter30, pitchRange120, stillness120
    case standing
}

enum HunchFeatureSet {
    static let legacyCount = HunchFeature.allCases.count
    static let count = legacyCount + HunchExtra.allCases.count
    /// 16 minutes of 1 Hz history: enough for the 15-minute drift and "your usual" baseline.
    static let traceLength = 960
    static let window = 30
    static let driftLookback = 300

    /// legacy 8 + extras, for the moment `lead` seconds before the end of `trace`.
    static func vector(trace: [PostureReading], lead: Int, deskMode: DeskMode?) -> [Double]? {
        let h = Array(trace.dropLast(max(0, lead)))
        guard let legacy = legacy(h) else { return nil }
        return legacy + extras(h, deskMode: deskMode)
    }

    /// Model input for an answer recorded before full history was stored: extras are unknown.
    static func legacyOnly(_ legacy: [Double]) -> [Double] {
        legacy + [Double](repeating: .nan, count: HunchExtra.allCases.count)
    }

    static func legacy(_ history: [PostureReading]) -> [Double]? {
        guard history.count >= window else { return nil }
        let w = history.suffix(window)
        let n = Double(w.count)
        let pitches = w.map(\.pitch)
        let meanPitch = pitches.reduce(0, +) / n
        let std = (pitches.map { ($0 - meanPitch) * ($0 - meanPitch) }.reduce(0, +) / n).squareRoot()
        let oldEnd = max(window, history.count - driftLookback + window)
        let old = history.prefix(min(oldEnd, history.count)).suffix(window)
        let oldPitch = old.map(\.pitch).reduce(0, +) / Double(max(1, old.count))

        var f = [Double](repeating: 0, count: legacyCount)
        f[HunchFeature.meanPitch.rawValue] = meanPitch
        f[HunchFeature.meanSideTilt.rawValue] = w.map { abs($0.roll) }.reduce(0, +) / n
        f[HunchFeature.meanForwardCM.rawValue] = w.map(\.forwardCM).reduce(0, +) / n
        f[HunchFeature.meanDropCM.rawValue] = w.map(\.dropCM).reduce(0, +) / n
        f[HunchFeature.pitchSteadiness.rawValue] = std
        f[HunchFeature.pitchDrift.rawValue] = meanPitch - oldPitch
        f[HunchFeature.lookingDownFraction.rawValue] = Double(w.filter { $0.pitch > 15 }.count) / n
        f[HunchFeature.chinPokeFraction.rawValue] = Double(w.filter(HunchDetector.chinPoke).count) / n
        return f
    }

    static func extras(_ h: [PostureReading], deskMode: DeskMode?) -> [Double] {
        let w10 = Array(h.suffix(10)), w30 = Array(h.suffix(30)), w120 = Array(h.suffix(120))
        let p = { (w: [PostureReading]) in w.map(\.pitch) }
        let fw = { (w: [PostureReading]) in w.map(\.forwardCM) }
        let dr = { (w: [PostureReading]) in w.map(\.dropCM) }

        // ~15 minutes ago (or the oldest 30 s we have)
        let oldStart = max(0, h.count - 900 - 30)
        let old = Array(h[oldStart..<min(h.count, oldStart + 30)])

        var e = [Double](repeating: 0, count: HunchExtra.allCases.count)
        e[HunchExtra.pitch10.rawValue] = mean(p(w10))
        e[HunchExtra.forward10.rawValue] = mean(fw(w10))
        e[HunchExtra.drop10.rawValue] = mean(dr(w10))
        e[HunchExtra.pitch120.rawValue] = mean(p(w120))
        e[HunchExtra.forward120.rawValue] = mean(fw(w120))
        e[HunchExtra.drop120.rawValue] = mean(dr(w120))
        e[HunchExtra.forwardWobble30.rawValue] = std(fw(w30))
        e[HunchExtra.dropWobble30.rawValue] = std(dr(w30))
        e[HunchExtra.sideLean30.rawValue] = mean(w30.map(\.roll))
        e[HunchExtra.pitchTrend120.rawValue] = slopePerMinute(p(w120))
        e[HunchExtra.forwardTrend120.rawValue] = slopePerMinute(fw(w120))
        e[HunchExtra.dropTrend120.rawValue] = slopePerMinute(dr(w120))
        e[HunchExtra.pitchDrift15min.rawValue] = mean(p(w30)) - mean(p(old))
        e[HunchExtra.pitchVsUsual.rawValue] = mean(p(w30)) - median(p(h))
        e[HunchExtra.forwardVsUsual.rawValue] = mean(fw(w30)) - median(fw(h))
        e[HunchExtra.dropVsUsual.rawValue] = mean(dr(w30)) - median(dr(h))
        e[HunchExtra.chinPoke120.rawValue] = fraction(w120, HunchDetector.chinPoke)
        e[HunchExtra.lookingDown120.rawValue] = fraction(w120) { $0.pitch > 15 }
        let d30 = zip(w30.dropFirst(), w30).map { abs($0.pitch - $1.pitch) }
        e[HunchExtra.jitter30.rawValue] = mean(d30)
        e[HunchExtra.pitchRange120.rawValue] = (p(w120).max() ?? 0) - (p(w120).min() ?? 0)
        let d120 = zip(w120.dropFirst(), w120).map { abs($0.pitch - $1.pitch) }
        e[HunchExtra.stillness120.rawValue] = d120.isEmpty ? 0 : Double(d120.filter { $0 < 0.3 }.count) / Double(d120.count)
        e[HunchExtra.standing.rawValue] = deskMode.map { $0 == .standing ? 1 : 0 } ?? .nan
        return e
    }

    // MARK: Compact storage of head history (1 Hz, Int16 × 10 per channel)

    static func encode(_ readings: [PostureReading]) -> Data {
        var out = [Int16]()
        out.reserveCapacity(readings.count * 4)
        func q(_ v: Double) -> Int16 { Int16(max(-32767, min(32767, (v * 10).rounded()))) }
        for r in readings {
            out.append(q(r.pitch)); out.append(q(r.roll)); out.append(q(r.forwardCM)); out.append(q(r.dropCM))
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // Written as simple typed steps on purpose: as one big expression, older Swift compilers
    // (e.g. Swift 6.2 on macOS 26) fail with "unable to type-check this expression in reasonable time".
    static func decode(_ data: Data) -> [PostureReading] {
        let values: [Int16] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        var out: [PostureReading] = []
        out.reserveCapacity(values.count / 4)
        var i: Int = 0
        while i + 3 < values.count {
            let pitch: Double = Double(values[i]) / 10.0
            let roll: Double = Double(values[i + 1]) / 10.0
            let forward: Double = Double(values[i + 2]) / 10.0
            let drop: Double = Double(values[i + 3]) / 10.0
            out.append(PostureReading(tilt: 0, pitch: pitch, roll: roll, forwardCM: forward, dropCM: drop))
            i += 4
        }
        return out
    }

    // MARK: helpers

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    static func std(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    /// Least-squares slope, per minute, of a 1 Hz series.
    static func slopePerMinute(_ v: [Double]) -> Double {
        guard v.count > 2 else { return 0 }
        let n = Double(v.count), xm = (n - 1) / 2, ym = mean(v)
        var num = 0.0, den = 0.0
        for (i, y) in v.enumerated() { num += (Double(i) - xm) * (y - ym); den += (Double(i) - xm) * (Double(i) - xm) }
        return den > 0 ? num / den * 60 : 0
    }
    static func fraction(_ w: [PostureReading], _ test: (PostureReading) -> Bool) -> Double {
        w.isEmpty ? 0 : Double(w.filter(test).count) / Double(w.count)
    }
}

/// A labelled moment.
struct HunchExample: Codable, Equatable {
    /// The original 8 summary features at the moment you answered.
    var features: [Double]
    var hunched: Bool
    var date: Date
    /// What the model predicted for this moment *before* you answered (nil if there was no model yet).
    var predicted: Double? = nil
    /// The model's yes/no call before you answered (with its tuned threshold).
    var predictedHunched: Bool? = nil
    /// Head history up to the moment (1 Hz, compact). Answers from older versions don't have it.
    var trace: Data? = nil
    /// Seconds before the end of `trace` that the answer describes (taps: you've often started
    /// sitting up by the time you tap, so the moment is a few seconds earlier).
    var lead: Int? = nil
    var deskMode: DeskMode? = nil

    var hasHistory: Bool { trace != nil }
}
