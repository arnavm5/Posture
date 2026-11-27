import Foundation
import simd

/// The quick slouch test inside calibration: "slouch the way you usually do, and hold it", then
/// "sit up straight again".
///
/// Generic limits (15° forward, 5 cm) are a guess. Some people's slouch tips the head 30°, others' barely
/// tips it but pushes it forward. Comparing your own slouch with your own upright pose puts the limits
/// between the two, a bit nearer the slouch so normal work doesn't trip them. The second "sit up straight"
/// is also an independent re-measurement of your neutral pose: if it agrees with the first, averaging the
/// two makes the neutral more accurate; if not, that's worth telling you.
enum SlouchTest {
    /// One recorded sample: gravity, plus the position estimate at that moment.
    struct Sample {
        var gravity: SIMD3<Double>
        var forwardCM: Double
        var dropCM: Double
        /// Seconds since the step started.
        var time: Double
    }

    /// A held pose: the steadiest stretch near the end of a step.
    struct Hold: Equatable {
        var gravity: SIMD3<Double>
        var forwardCM: Double
        var dropCM: Double
        var spreadDegrees: Double
    }

    struct Outcome: Equatable {
        /// The calibration to use, with the neutral pose refined when both "sit up straight" poses agreed.
        var calibration: HeadCalibration
        /// New limits, or nil where the slouch didn't change that measure enough to tell.
        var forwardTilt: Double?
        var shiftCM: Double?
        /// How far your slouch tipped your head forward (degrees) and moved it (cm), vs. sitting up straight.
        var slouchTiltDegrees: Double
        var slouchShiftCM: Double
        /// How far apart your two "sit up straight" poses were (degrees).
        var neutralRepeatDegrees: Double
        var neutralRefined: Bool

        var sawSlouch: Bool { forwardTilt != nil || shiftCM != nil }
        /// The two upright poses disagreed by more than a re-seat of the AirPods explains.
        var neutralInconsistent: Bool { neutralRepeatDegrees > SlouchTest.maxNeutralRepeat }
    }

    /// Where the limit goes, from upright (0) to your slouch (1).
    static let fraction = 0.6
    /// The slouch must change a measure at least this much for its limit to be set from it.
    static let minTiltChange = 12.0
    static let minShiftChange = 3.0
    /// A limit must sit at least this far inside your slouch, or the slouch you just showed wouldn't trip it.
    static let tiltMargin = 2.0
    static let shiftMargin = 1.0
    /// Personal limits stay within these (as tight as is practical, as loose as still catches a slouch).
    static let tiltRange = 10.0...30.0
    static let shiftRange = 3.0...12.0
    /// Both "sit up straight" poses within this many degrees: average them (unless the second is the more
    /// slouched one: people often don't fully straighten after slouching).
    static let maxNeutralRepeat = 5.0
    static let maxSecondForward = 1.0
    /// A hold wobbling more than this (RMS degrees) wasn't held.
    static let maxHoldSpread = 2.5

    /// Samples per second the AirPods send; a step with far fewer samples than this means the signal dropped.
    static let sampleRate = 25.0
    /// Each step needs at least this many seconds' worth of samples.
    static let minSampleSeconds = 2.0
    /// Where the held pose is looked for: the last few seconds of each step, steadiest 1.5 s.
    static let slouchHoldSeconds = 3.0
    static let uprightHoldSeconds = 2.5
    static let holdWindow = 1.5

    enum Result: Equatable {
        case evaluated(Outcome)
        /// Too few samples in a step: the signal dropped.
        case signalDropped
        /// No steady stretch in a step: you kept moving.
        case keptMoving
    }

    /// The whole test from the two steps' samples: checks the signal, finds each held pose, evaluates.
    static func run(calibration: HeadCalibration, slouch: [Sample], sitTall: [Sample],
                    currentTiltLimit: Double) -> Result {
        let expected: Double = sampleRate * minSampleSeconds
        guard Double(slouch.count) > expected, Double(sitTall.count) > expected else { return .signalDropped }
        guard let slouched = hold(slouch, lastSeconds: slouchHoldSeconds, window: holdWindow),
              let upright = hold(sitTall, lastSeconds: uprightHoldSeconds, window: holdWindow) else { return .keptMoving }
        return .evaluated(evaluate(calibration: calibration, slouched: slouched, upright: upright,
                                   currentTiltLimit: currentTiltLimit))
    }

    /// The steadiest `window` seconds within the last `lastSeconds` of a step (you take a moment to
    /// get into the pose, so the start of the step isn't used).
    static func hold(_ samples: [Sample], lastSeconds: Double, window: Double) -> Hold? {
        guard let end = samples.last?.time else { return nil }
        let recent = samples.filter { $0.time >= end - lastSeconds }
        guard recent.count >= 5 else { return nil }
        let span: Double = max(0.04, end - (recent.first?.time ?? end))
        let rate: Double = Double(recent.count - 1) / span
        let count = max(5, Int((window * rate).rounded()))
        guard let steady = CalibrationMath.steadiest(recent.map(\.gravity), window: count),
              steady.spreadDegrees <= maxHoldSpread else { return nil }
        var forward: Double = 0, drop: Double = 0
        for i in steady.range {
            forward += recent[i].forwardCM
            drop += recent[i].dropCM
        }
        let n = Double(steady.range.count)
        return Hold(gravity: steady.mean, forwardCM: forward / n, dropCM: drop / n, spreadDegrees: steady.spreadDegrees)
    }

    /// - Parameters:
    ///   - calibration: solved from the earlier steps (the position estimates were made with it).
    ///   - slouched: the held slouch.
    ///   - upright: the held "sit up straight again".
    ///   - currentTiltLimit: the forward-tilt limit in use, if the test doesn't set a new one.
    static func evaluate(calibration: HeadCalibration, slouched: Hold, upright: Hold,
                         currentTiltLimit: Double = 15) -> Outcome {
        let repeatDegrees: Double = CalibrationMath.angle(upright.gravity, calibration.neutralGravity) * 180 / .pi
        var final = calibration
        let refined = repeatDegrees <= maxNeutralRepeat && pitch(upright.gravity, calibration) <= maxSecondForward
        if refined {
            let sum: SIMD3<Double> = simd_normalize(calibration.neutralGravity) + simd_normalize(upright.gravity)
            final = calibration.withNeutral(sum)
        }

        // Forward tilt, measured against the final neutral pose. If you didn't quite sit all the way back
        // up, that's what your upright looks like, so the limit starts from there.
        let slouchPitch = pitch(slouched.gravity, final)
        let uprightPitch = max(0, pitch(upright.gravity, final))
        let tiltChange: Double = slouchPitch - uprightPitch
        var tiltLimit: Double?
        if tiltChange >= minTiltChange {
            let raw: Double = uprightPitch + fraction * tiltChange
            let limit = clamp(raw.rounded(), tiltRange)
            if limit <= slouchPitch - tiltMargin { tiltLimit = limit }
        }

        // Head shift. `forwardCM` / `dropCM` include the neck movement that tipping the head implies, so a
        // plain tilt reads as a few cm too. Only a real translation (a forward-head slouch) sets this limit:
        // the slouch must stand out from where you started (0) *and* from where you sat back up to, so a
        // position estimate that drifted, or a return that wasn't tracked, doesn't count.
        let kS = kinematics(slouched.gravity, calibration), kU = kinematics(upright.gravity, calibration)
        let moveForward: Double = min(slouched.forwardCM - kS.forward,
                                      (slouched.forwardCM - kS.forward) - (upright.forwardCM - kU.forward))
        let moveDown: Double = min(slouched.dropCM - kS.drop, (slouched.dropCM - kS.drop) - (upright.dropCM - kU.drop))
        let alongForward = moveForward >= moveDown
        let translation: Double = max(moveForward, moveDown)
        var shiftLimit: Double?
        if translation >= minShiftChange {
            // The limit applies to the full reading, so it's placed on the full reading's change…
            let total: Double = alongForward
                ? min(slouched.forwardCM, slouched.forwardCM - upright.forwardCM)
                : min(slouched.dropCM, slouched.dropCM - upright.dropCM)
            // …but never so low that tipping the head (short of the tilt limit) trips it on its own. The one
            // limit applies to forward *and* drop readings, and tipping reads mostly as forward, so the floor is
            // the forward reading of tipping to the tilt limit, whichever way your slouch moved.
            let tiltRad: Double = (tiltLimit ?? currentTiltLimit) * .pi / 180
            let fromTilt: Double = PostureEstimator.neckLever * sin(tiltRad) * 100
            let raw: Double = fraction * total
            let limit = clamp(max(raw.rounded(), fromTilt.rounded(.up)), shiftRange)   // up: never below the tipping shift
            if limit <= total - shiftMargin { shiftLimit = limit }
        }

        return Outcome(calibration: final, forwardTilt: tiltLimit, shiftCM: shiftLimit,
                       slouchTiltDegrees: tiltChange, slouchShiftCM: max(0, translation),
                       neutralRepeatDegrees: repeatDegrees, neutralRefined: refined)
    }

    /// Degrees the head is tipped forward (+) in the calibrated frame.
    static func pitch(_ gravity: SIMD3<Double>, _ cal: HeadCalibration) -> Double {
        let s: Double = simd_dot(simd_normalize(gravity), cal.forward)
        return asin(min(1, max(-1, s))) * 180 / .pi
    }

    /// The part of the position reading that comes from tipping the head on the neck (as in
    /// `PostureEstimator.reading`), in cm.
    static func kinematics(_ gravity: SIMD3<Double>, _ cal: HeadCalibration) -> (forward: Double, drop: Double) {
        let p: Double = pitch(gravity, cal) * .pi / 180
        let tilt: Double = CalibrationMath.angle(gravity, cal.neutralGravity)
        let forward: Double = PostureEstimator.neckLever * sin(p) * 100
        let drop: Double = PostureEstimator.neckLever * (1 - cos(tilt)) * 100
        return (forward, drop)
    }

    private static func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, x)) }
}
