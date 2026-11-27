import Foundation

/// Turns second-by-second hunch evidence into a steady yes/no, with a real probability behind it.
///
/// A two-state hidden Markov filter: you're either hunched or not, and each state tends to last
/// (a good stretch typically lasts many minutes, a hunch several). Every second the evidence (from your
/// personal model, or the built-in rules) nudges the probability up or down; the "states last" prior keeps a
/// single odd second from flipping it. Compared with counting hunchy seconds:
///  - **Graded:** a clear hunch is flagged sooner than a borderline one.
///  - **No cliff:** a short break lowers the probability by how convincing the break was, instead of
///    resetting a counter after a fixed number of seconds.
///  - **Asymmetric:** sitting tall is strong evidence, so a real correction clears the flag quickly.
struct HunchStateFilter {
    /// Seconds of steady, ordinary hunch evidence (rule firing, or the model just past its cutoff) needed to
    /// go from settled-upright to flagged.
    let secondsToFlag: Int
    /// Mean length of a good stretch and of a hunch, seconds (the per-second switching chances).
    static let meanGoodSeconds = 1800.0
    static let meanHunchSeconds = 600.0
    /// Sitting tall counts this many times as strongly as hunchy evidence.
    static let uprightWeight = 2.5
    /// Probability thresholds: flag at or above `enter`, clear at or below `leave` (hysteresis).
    static let enter = 0.8
    static let leave = 0.3
    /// Strongest evidence, in units of "ordinary" evidence.
    static let maxStrength = 1.5

    private static let defaultStep = step(forSecondsToFlag: 60)

    /// Log-odds added per second by ordinary hunchy evidence (derived from `secondsToFlag`).
    let step: Double
    private(set) var probability: Double
    private(set) var isHunched = false

    init(secondsToFlag: Int = 60) {
        self.secondsToFlag = secondsToFlag
        step = secondsToFlag == 60 ? Self.defaultStep : Self.step(forSecondsToFlag: secondsToFlag)
        probability = Self.settledProbability(step: step)
    }

    mutating func reset() {
        probability = Self.settledProbability(step: step)
        isHunched = false
    }

    /// One second of evidence: + for hunched, − for not, ±1 = ordinary, up to ±`maxStrength`.
    @discardableResult
    mutating func add(evidence: Double) -> Bool {
        probability = Self.next(probability, evidence: evidence, step: step)
        if isHunched { isHunched = probability > Self.leave } else { isHunched = probability >= Self.enter }
        return isHunched
    }

    /// Evidence from your personal model: how far its probability is past its cutoff, in log-odds.
    /// Within 0.1 of the cutoff it's unsure and the caller should use the rules instead (nil).
    static func modelEvidence(probability p: Double, threshold: Double) -> Double? {
        guard abs(p - threshold) >= 0.1 - 1e-9 else { return nil }      // tolerance: 0.6 − 0.5 < 0.1 in floating point
        let d: Double = logit(p) - logit(threshold)
        let edge: Double = logit(min(0.99, threshold + 0.1)) - logit(threshold)   // log-odds at the unsure band's edge
        let strength: Double = min(maxStrength, max(1, abs(d) / max(edge, 1e-3)))
        return d > 0 ? strength : -strength
    }

    // MARK: The filter

    static func next(_ p: Double, evidence: Double, step: Double) -> Double {
        let toHunch: Double = 1 / meanGoodSeconds
        let toGood: Double = 1 / meanHunchSeconds
        let prior: Double = p * (1 - toGood) + (1 - p) * toHunch
        let weight: Double = evidence >= 0 ? 1 : uprightWeight
        let z: Double = logit(prior) + evidence * weight * step
        return 1 / (1 + exp(-max(-30, min(30, z))))
    }

    /// Where the probability settles after a long stretch of sitting tall.
    static func settledProbability(step: Double) -> Double {
        var p: Double = 0.5
        for _ in 0..<2000 { p = next(p, evidence: -1, step: step) }
        return p
    }

    /// Seconds of ordinary hunchy evidence to go from settled-upright to flagged.
    static func secondsToFlag(step: Double) -> Int {
        var p: Double = settledProbability(step: step)
        var n: Int = 0
        while p < enter && n < 100_000 {
            p = next(p, evidence: 1, step: step)
            n += 1
        }
        return n
    }

    /// Solves for the step size that flags after `seconds` (bisection: a bigger step flags sooner).
    static func step(forSecondsToFlag seconds: Int) -> Double {
        var lo: Double = 0.005, hi: Double = 5
        for _ in 0..<40 {
            let mid: Double = (lo + hi) / 2
            if secondsToFlag(step: mid) > seconds { lo = mid } else { hi = mid }
        }
        return hi
    }

    static func logit(_ p: Double) -> Double {
        let q: Double = max(1e-9, min(1 - 1e-9, p))
        return log(q / (1 - q))
    }
}
