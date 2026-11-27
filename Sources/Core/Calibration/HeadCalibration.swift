import Foundation
import simd

/// Which earbud the motion data comes from. Each earbud sits differently, so each gets its own calibration.
enum Earbud: String, Codable {
    case unknown, left, right
}

/// Everything the app knows about how *your* AirPods sit on *your* head.
///
/// Built from the calibration steps:
///  1. sit tall, looking at the screen  → neutral gravity (the "up" axis), from the steadiest stretch
///  2. look down at the keyboard and back → the head's forward axis, fitted to the whole nod
///  (optional slouch test: slouch, then sit tall again → personal limits and a refined neutral; see `SlouchTest`)
///  3. turn left and right               ┐ rotations about different axes, used to fit the
///  4. tilt each ear toward the shoulder ┘ lever arm (earbud ↔ neck pivot) for swing compensation
struct HeadCalibration: Codable, Equatable {
    var neutralGravity: SIMD3<Double>
    var forward: SIMD3<Double>
    var leverArm: SIMD3<Double>
    var leverFitted: Bool
    var earbud: Earbud = .unknown
    /// Sitting or standing when this calibration was made (nil in older saves = sitting).
    var deskMode: DeskMode? = nil
    /// How clean the recording was (nil in older saves).
    var quality: Quality? = nil

    struct Quality: Codable, Equatable {
        /// RMS wobble of the head (degrees) during the steadiest stretch of "sit up straight".
        var neutralSpreadDegrees: Double
        /// How far the look-down went (degrees).
        var nodDegrees: Double
        /// 0…1: how much of the look-down was a straight nod (1) rather than turning or tilting sideways.
        var nodStraightness: Double
    }

    /// Head axes in the AirPods' frame.
    var up: SIMD3<Double> { -simd_normalize(neutralGravity) }
    var left: SIMD3<Double> { simd_normalize(simd_cross(up, forward)) }

    /// Default lever arm when it can't be fitted: earbud ≈ 9 cm above the neck pivot.
    static func defaultLever(neutralGravity g0: SIMD3<Double>) -> SIMD3<Double> { -simd_normalize(g0) * 0.09 }

    enum Failure: Error, Equatable {
        case noSignal
        case didNotLookDown
        case notStill
    }

    /// Samples in the stretch of "sit up straight" that's used (≈1.5 s at 25 Hz).
    static let steadyWindow = 38
    /// A stretch this steady (RMS degrees) counts as holding the pose.
    static let steadyDegrees = 0.7
    /// More head wobble than this (RMS, degrees) while sitting tall means you weren't holding still.
    static let maxNeutralSpread = 2.5
    /// "Sit up straight" ignores your first moments (you're still reading the prompt and settling), ends as
    /// soon as you've held still long enough, and otherwise keeps going until its time runs out.
    static let reactionSeconds = 0.75
    static let neutralMinSeconds = 3.0

    /// Whether a "sit up straight" sample taken `phaseTime` seconds into the step is recorded.
    static func recordsNeutral(at phaseTime: Double) -> Bool { phaseTime > reactionSeconds }

    /// Whether "sit up straight" can end now: at least `neutralMinSeconds` in, and the latest ~1.5 s held steady.
    static func neutralIsHeld(_ samples: [SIMD3<Double>], phaseTime: Double) -> Bool {
        let n = steadyWindow
        guard phaseTime >= neutralMinSeconds, samples.count >= n,
              let recent = CalibrationMath.steadiest(Array(samples.suffix(n)), window: n) else { return false }
        return recent.spreadDegrees < steadyDegrees
    }

    /// Solves the calibration from the recorded steps.
    static func solve(neutral: [SIMD3<Double>], lookDown: [SIMD3<Double>], leverFit: LeverArmFit,
                      earbud: Earbud, deskMode: DeskMode = .sitting) -> Result<HeadCalibration, Failure> {
        // Use the steadiest stretch, not the average of everything: the start of the step often still
        // has you settling into position, and that would tilt the neutral pose.
        // The *latest* steady stretch, if there is one: if you held still and then adjusted, the pose you
        // adjusted into is the one you meant.
        guard let steady = CalibrationMath.steadiest(neutral, window: steadyWindow, preferLatestBelow: steadyDegrees)
        else { return .failure(.noSignal) }
        guard steady.spreadDegrees <= maxNeutralSpread else { return .failure(.notStill) }
        let g0 = steady.mean
        guard let nod = CalibrationMath.nod(neutral: g0, samples: lookDown) else { return .failure(.didNotLookDown) }

        let prior = defaultLever(neutralGravity: g0)
        let fit = leverFit.solve(prior: prior)
        let quality = Quality(neutralSpreadDegrees: steady.spreadDegrees, nodDegrees: nod.degrees,
                              nodStraightness: nod.straightness)
        return .success(HeadCalibration(neutralGravity: g0, forward: nod.axis, leverArm: fit?.lever ?? prior,
                                        leverFitted: fit != nil, earbud: earbud, deskMode: deskMode, quality: quality))
    }

    /// The same calibration with a new neutral pose. The forward axis turns with it (the smallest rotation
    /// taking the old neutral to the new one), so forward and side tilt stay separated.
    func withNeutral(_ gravity: SIMD3<Double>) -> HeadCalibration {
        let g0 = simd_normalize(neutralGravity), n = simd_normalize(gravity)
        let turn = simd_quatd(from: g0, to: n)
        var f: SIMD3<Double> = turn.act(forward)
        let along: Double = simd_dot(f, n)
        f = simd_normalize(f - n * along)
        var out = self
        out.neutralGravity = n
        out.forward = f
        return out
    }

    // MARK: Persistence (one calibration per earbud, and per sitting / standing)

    /// The best saved calibration for this earbud and position, falling back to: this earbud sitting,
    /// then calibrations made when the earbud couldn't be identified (and older versions' calibrations).
    static func best(for earbud: Earbud, mode: DeskMode) -> HeadCalibration? {
        var order: [(Earbud, DeskMode)] = [(earbud, mode), (earbud, .sitting)]
        if earbud != .unknown { order += [(.unknown, mode), (.unknown, .sitting)] }
        for (e, m) in order { if let c = load(for: e, mode: m) { return c } }
        return nil
    }

    static func key(_ e: Earbud, _ mode: DeskMode = .sitting) -> String {
        "calibration.\(e.rawValue)" + (mode == .standing ? ".standing" : "")
    }

    static func load(for earbud: Earbud, mode: DeskMode = .sitting) -> HeadCalibration? {
        guard let data = UserDefaults.standard.data(forKey: key(earbud, mode)) else { return nil }
        return try? JSONDecoder().decode(HeadCalibration.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(earbud, deskMode ?? .sitting))
        }
    }
}

/// Turns noisy calibration recordings into steady values.
enum CalibrationMath {
    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }

    /// The steadiest run of `window` consecutive samples (all of them if there are fewer): where it is,
    /// its mean direction, and its RMS spread around that mean in degrees. With `preferLatestBelow`, the
    /// latest run at least that steady wins instead (falling back to the steadiest).
    static func steadiest(_ samples: [SIMD3<Double>], window: Int,
                          preferLatestBelow latestDegrees: Double? = nil) -> (range: Range<Int>, mean: SIMD3<Double>, spreadDegrees: Double)? {
        guard !samples.isEmpty else { return nil }
        let w = max(1, min(window, samples.count))
        var best: (range: Range<Int>, mean: SIMD3<Double>, spread: Double)?
        var latest: (range: Range<Int>, mean: SIMD3<Double>, spread: Double)?
        let latestLimit: Double = (latestDegrees ?? -1) * .pi / 180
        for start in 0...(samples.count - w) {
            let range = start..<(start + w)
            var sum = SIMD3<Double>.zero
            for i in range { sum += simd_normalize(samples[i]) }
            guard simd_length(sum) > 1e-9 else { continue }
            let mean = simd_normalize(sum)
            var squared: Double = 0
            for i in range {
                let a = angle(samples[i], mean)
                squared += a * a
            }
            let rms: Double = (squared / Double(w)).squareRoot()
            if best == nil || rms < best!.spread { best = (range, mean, rms) }
            if rms <= latestLimit { latest = (range, mean, rms) }
        }
        guard let b = latest ?? best else { return nil }
        let degrees: Double = b.spread * 180 / .pi
        return (b.range, b.mean, degrees)
    }

    /// The look-down needs to tip the head at least this far.
    static let minNodDegrees = 10.0
    /// Samples closer than this to neutral are mostly noise and don't shape the axis.
    static let nodNoiseDegrees = 3.0

    /// The head's forward axis from a look-down-and-back. Seen from the neutral pose, gravity swings
    /// toward the forward axis as you nod, so the axis is the main direction of that swing: fitted to
    /// every sample of the nod (the dominant eigenvector of their spread), not only the lowest point,
    /// so a single noisy sample or a little turn at the bottom doesn't skew it.
    /// Returns nil if you didn't look down far enough.
    static func nod(neutral g0: SIMD3<Double>, samples: [SIMD3<Double>]) -> (axis: SIMD3<Double>, degrees: Double, straightness: Double)? {
        let n0 = simd_normalize(g0)
        let noise: Double = nodNoiseDegrees * .pi / 180
        var spread = simd_double3x3(0)
        var farthest = SIMD3<Double>.zero
        var farthestAngle: Double = 0
        for s in samples {
            let g = simd_normalize(s)
            let along: Double = simd_dot(g, n0)
            let p: SIMD3<Double> = g - n0 * along              // the swing away from neutral
            let a = angle(g, n0)
            if a > farthestAngle { farthestAngle = a; farthest = p }
            if a > noise { spread += outer(p, p) }
        }
        let degrees: Double = farthestAngle * 180 / .pi
        guard degrees > minNodDegrees, simd_length(farthest) > 1e-9 else { return nil }

        // Power iteration, starting from the lowest point (already close to the answer).
        var v = simd_normalize(farthest)
        for _ in 0..<60 {
            let next: SIMD3<Double> = spread * v
            let length = simd_length(next)
            guard length > 1e-12 else { break }
            v = next / length
        }
        if simd_dot(v, farthest) < 0 { v = -v }                   // point the way you looked
        let along: Double = simd_dot(v, n0)
        v = simd_normalize(v - n0 * along)
        let total: Double = spread[0][0] + spread[1][1] + spread[2][2]
        let major: Double = simd_dot(v, spread * v)
        let straightness: Double = total > 0 ? min(1, major / total) : 1
        return (v, degrees, straightness)
    }
}
