import Foundation
import simd

/// One run of the calibration sequence: sit tall → look down → *(slouch → sit tall again)* → turn → tilt.
///
/// Every decision lives here (which steps, what each records, when "sit tall" ends early, the slouch test, the
/// notes you're shown) so it can be tested. The app only supplies the clock (it calls `advance()` when a
/// step's time is up), the motion samples, and the UI.
struct CalibrationSession {
    enum Step: CaseIterable, Equatable {
        case neutral, lookDown, slouch, sitTall, turn, tilt

        /// How long each step lasts at most.
        var seconds: Double {
            switch self {
            case .neutral: 8
            case .lookDown: 4
            case .slouch: 6
            case .sitTall, .turn, .tilt: 4
            }
        }

        func prompt(standing: Bool) -> String {
            let tall = standing ? "Stand up straight" : "Sit up straight"
            switch self {
            case .neutral: return "\(tall) and look at your screen…"
            case .lookDown: return "Slowly look down at your keyboard, then back up…"
            case .slouch: return "Now slouch the way you usually do, and hold it…"
            case .sitTall: return "\(tall) again, looking at your screen…"
            case .turn: return "Turn your head slowly left, then right…"
            case .tilt: return "Tilt your ear toward each shoulder…"
            }
        }
    }

    /// What `advance()` led to.
    enum Advance: Equatable {
        case next(Step)
        case finished
        /// The slouch test couldn't start: the first two steps went wrong.
        case failed(HeadCalibration.Failure)
    }

    /// A finished calibration, with the limits the slouch test set (nil = keep yours) and what to tell you.
    struct Finished {
        var calibration: HeadCalibration
        var forwardTilt: Double?
        var shiftCM: Double?
        var notes: [String]
        /// The slouch test's measurements, when it ran and was evaluated (for the log).
        var slouchTest: SlouchTest.Outcome?
    }

    static let withSlouchTest: [Step] = [.neutral, .lookDown, .slouch, .sitTall, .turn, .tilt]
    static let withoutSlouchTest: [Step] = [.neutral, .lookDown, .turn, .tilt]

    let steps: [Step]
    let earbud: Earbud
    let deskMode: DeskMode
    private(set) var index = 0
    private(set) var stepTime = 0.0
    private(set) var neutralSamples: [SIMD3<Double>] = []
    private(set) var lookDownSamples: [SIMD3<Double>] = []
    private(set) var slouchSamples: [SlouchTest.Sample] = []
    private(set) var sitTallSamples: [SlouchTest.Sample] = []
    private var leverFit = LeverArmFit()
    /// Slouch test: a provisional calibration (from the first two steps) and its own estimator.
    private var provisional: HeadCalibration?
    private var testEstimator: PostureEstimator?

    init(slouchTest: Bool, earbud: Earbud, deskMode: DeskMode) {
        steps = slouchTest ? Self.withSlouchTest : Self.withoutSlouchTest
        self.earbud = earbud
        self.deskMode = deskMode
    }

    var step: Step { steps[index] }
    /// "Step 2 of 6".
    var progress: (index: Int, of: Int) { (index + 1, steps.count) }
    var prompt: String { step.prompt(standing: deskMode == .standing) }

    /// The lever arm the compensator should use during this step. The lever fit needs raw acceleration, so
    /// no compensation, except while slouching: that's measured with the provisional calibration's lever
    /// (slouching is slow, so the default lever is plenty).
    var compensatorLever: SIMD3<Double> {
        switch step {
        case .slouch, .sitTall: provisional?.leverArm ?? .zero
        default: .zero
        }
    }

    /// Moves to the next step (its time ran out, or it ended early).
    mutating func advance() -> Advance {
        guard index + 1 < steps.count else { return .finished }
        let next = steps[index + 1]
        if next == .slouch {
            switch HeadCalibration.solve(neutral: neutralSamples, lookDown: lookDownSamples, leverFit: LeverArmFit(),
                                         earbud: earbud, deskMode: deskMode) {
            case .success(let cal):
                provisional = cal
                testEstimator = PostureEstimator(calibration: cal)
            case .failure(let f):
                return .failed(f)       // fail now, not after the whole sequence
            }
        }
        index += 1
        stepTime = 0
        return .next(next)
    }

    /// Records one motion sample. Returns true when the step is done early (you held "sit up straight").
    mutating func record(_ k: HeadKinematics) -> Bool {
        stepTime += k.dt
        switch step {
        case .neutral:
            guard HeadCalibration.recordsNeutral(at: stepTime) else { return false }
            neutralSamples.append(k.gravity)
            return HeadCalibration.neutralIsHeld(neutralSamples, phaseTime: stepTime)
        case .lookDown:
            lookDownSamples.append(k.gravity)
            leverFit.add(k)
        case .slouch, .sitTall:
            guard var est = testEstimator else { return false }
            est.ingest(gravity: k.gravity, translational: k.translational, omega: k.omega, dt: k.dt)
            testEstimator = est
            let r = est.reading(gravity: k.gravity)
            let sample = SlouchTest.Sample(gravity: k.gravity, forwardCM: r.forwardCM, dropCM: r.dropCM, time: stepTime)
            if step == .slouch { slouchSamples.append(sample) } else { sitTallSamples.append(sample) }
        case .turn, .tilt:
            leverFit.add(k)
        }
        return false
    }

    /// Solves the calibration from everything recorded, applies the slouch test, and words the notes.
    /// - Parameters: the limits in use now (the slouch test may replace them).
    func finish(currentTiltLimit: Double, currentShiftCM: Double) -> Result<Finished, HeadCalibration.Failure> {
        let solved = HeadCalibration.solve(neutral: neutralSamples, lookDown: lookDownSamples, leverFit: leverFit,
                                           earbud: earbud, deskMode: deskMode)
        guard case .success(let cal) = solved else {
            if case .failure(let f) = solved { return .failure(f) }
            return .failure(.noSignal)
        }
        var done = Finished(calibration: cal, forwardTilt: nil, shiftCM: nil, notes: [], slouchTest: nil)
        if steps.contains(.slouch) { applySlouchTest(to: &done, currentTiltLimit: currentTiltLimit, currentShiftCM: currentShiftCM) }
        if let q = done.calibration.quality, q.nodStraightness < 0.75 {
            done.notes.append("Your look-down also turned your head sideways; nodding straight down gives a more accurate forward direction.")
        }
        if !done.calibration.leverFitted {
            done.notes.append("For the most accurate position tracking, make the turn and tilt moves a little bigger next time.")
        }
        return .success(done)
    }

    private func applySlouchTest(to done: inout Finished, currentTiltLimit: Double, currentShiftCM: Double) {
        let outcome: SlouchTest.Outcome
        switch SlouchTest.run(calibration: done.calibration, slouch: slouchSamples, sitTall: sitTallSamples,
                              currentTiltLimit: currentTiltLimit) {
        case .signalDropped:
            done.notes.append("The AirPods signal dropped during the slouch test, so your limits stay as they were.")
            return
        case .keptMoving:
            done.notes.append("You kept moving during the slouch test, so your limits stay as they were.")
            return
        case .evaluated(let o):
            outcome = o
        }
        done.slouchTest = outcome
        done.calibration = outcome.calibration
        // Old → new, so a limit you had tuned by hand is easy to put back.
        var set: [String] = []
        if let t = outcome.forwardTilt {
            set.append("forward tilt \(Int(currentTiltLimit))° → \(Int(t))°")
            done.forwardTilt = t
        }
        if let c = outcome.shiftCM {
            set.append("head shift \(Int(currentShiftCM)) → \(Int(c)) cm")
            done.shiftCM = c
        }
        let mode = deskMode.label.lowercased()
        if outcome.sawSlouch {
            done.notes.append("Your \(mode) limits now fit your slouch: \(set.joined(separator: ", ")).")
        } else {
            done.notes.append("Your slouch barely moved your head, so your \(mode) limits stay as they were.")
        }
        if outcome.neutralInconsistent {
            done.notes.append(String(format: "Your two upright poses differed by %.0f°; recalibrate if the readings look off.",
                                     outcome.neutralRepeatDegrees))
        }
    }
}

extension HeadCalibration.Failure {
    /// What went wrong, in words.
    func message(deskMode: DeskMode) -> String {
        switch self {
        case .noSignal: "Lost the AirPods signal. Try again."
        case .didNotLookDown: "Didn't see you look down. Try again and tip your head further."
        case .notStill: "You were moving while \(deskMode == .standing ? "standing" : "sitting") up straight. Try again and hold still for a moment."
        }
    }
}
