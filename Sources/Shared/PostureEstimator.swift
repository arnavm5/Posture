import Foundation
import simd

struct PostureReading {
    var tilt: Double = 0          // degrees away from neutral, any direction
    var pitch: Double = 0         // degrees, + = head tipped forward/down
    var roll: Double = 0          // degrees, + = left ear toward left shoulder
    var forwardCM: Double = 0     // head position vs neutral, + = toward the screen
    var dropCM: Double = 0        // + = head lower than neutral (sinking into the chair)
    var forwardSigmaCM: Double = 0
    var dropSigmaCM: Double = 0
}

/// Estimates head orientation *and position* from AirPods motion alone.
///
/// Orientation comes from gravity in the calibrated head frame (forward tilt and side tilt are
/// separate). Position combines:
///  1. Kinematics: the head pivots on the neck, so tipping forward moves it forward and down.
///  2. A Kalman filter per axis (up, forward) driven by *translational* acceleration, meaning the
///     earbud's swing around the neck has already been removed (see `LeverArmCompensator`).
///     Zero-velocity updates whenever you're still keep it from drifting and calibrate out bias.
/// Very slow drifts are below the sensor's noise floor and can't be seen; the filter's
/// uncertainty (`forwardSigmaCM`, `dropSigmaCM`) says how much to trust the position.
struct PostureEstimator {
    /// Your calibration, with the neutral pose gently following small AirPod shifts (see `adaptNeutral`).
    private(set) var calibration: HeadCalibration
    /// The neutral pose as saved by calibration; adaptation never strays more than `adaptCap` from it.
    let savedNeutral: SIMD3<Double>

    private var upFilter: ZUPTKalman = ZUPTKalman()
    private var forwardFilter: ZUPTKalman = ZUPTKalman()
    private var stillness = StillnessDetector()
    private var lowPassed = SIMD3<Double>.zero
    private var motionStartGravity: SIMD3<Double>?
    private var motionRotation = 0.0
    private var motionStartTilt = 0.0          // head angle away from neutral when the movement began
    private var motionTime = 0.0
    private var discardMotion = false
    /// Filter state just before the current movement began (restored if the movement is abandoned).
    private var beforeMotion: (up: ZUPTKalman, fwd: ZUPTKalman)?
    // Look-back buffer: movement is only recognised a few samples after it starts. Until then the
    // filter assumes "still" and pins velocity to zero, which would cut off the start of the motion.
    // On detection we rewind to the oldest buffered state and replay without zero-velocity updates.
    private var lookBack: [(up: ZUPTKalman, fwd: ZUPTKalman, aUp: Double, aFwd: Double, noise: Double, dt: Double)] = []
    static let lookBackTime = 0.5

    static let neckLever = 0.12          // ear height above the lower-neck pivot (m), for kinematics
    static let maxMotion = 4.0           // s of continuous motion before we give up (standing, walking…)
    static let relaxSeconds = 8 * 3600.0  // fade-back time constant for leftover offsets (8 h: overnight scale)
    /// Neutral-pose adaptation: time constant, only within this angle of neutral, never more than `adaptCap`
    /// away from the saved calibration in total.
    static let adaptSeconds = 15 * 60.0
    static let adaptWithin = 6 * Double.pi / 180
    static let adaptCap = 4 * Double.pi / 180

    var shiftForward: Double { forwardFilter.position }
    var shiftUp: Double { upFilter.position }

    init(calibration: HeadCalibration) {
        self.calibration = calibration
        self.savedNeutral = simd_normalize(calibration.neutralGravity)
    }

    var isStill: Bool { stillness.isStill }

    /// How far (degrees) the neutral pose has drifted from the saved calibration to follow AirPod shifts.
    var neutralDriftDegrees: Double { angle(calibration.neutralGravity, savedNeutral) * 180 / .pi }

    /// Lets the neutral pose slowly follow small shifts in how the AirPods sit in your ears.
    ///
    /// Call only while you're rated as sitting well, holding still. It only moves toward poses within 6° of
    /// the current neutral, takes ~15 minutes to follow, and never strays more than 4° from your saved
    /// calibration in total, so a slow slouch can't be absorbed as the new normal (your limits are 12–15°).
    /// The forward axis turns with it, so forward and side tilt stay correctly separated.
    mutating func adaptNeutral(toward gravity: SIMD3<Double>, dt: Double) {
        let g = simd_normalize(gravity), g0 = simd_normalize(calibration.neutralGravity)
        guard angle(g, g0) < Self.adaptWithin else { return }
        var n = simd_normalize(g0 + (g - g0) * (1 - exp(-dt / Self.adaptSeconds)))
        let drift = angle(n, savedNeutral)
        if drift > Self.adaptCap {                       // hold at the cap, in the direction it was going
            let axis = simd_normalize(n - simd_dot(n, savedNeutral) * savedNeutral)
            n = simd_normalize(savedNeutral * cos(Self.adaptCap) + axis * sin(Self.adaptCap))
        }
        let turn = simd_quatd(from: g0, to: n)
        var f = turn.act(calibration.forward)
        f = simd_normalize(f - simd_dot(f, n) * n)
        calibration.neutralGravity = n
        calibration.forward = f
    }

    mutating func resetPosition() {
        resetFilters()
        motionStartGravity = nil
        discardMotion = false
    }

    private mutating func resetFilters() {
        upFilter.resetPosition()
        forwardFilter.resetPosition()
        // Forget pre-reset history too: otherwise a movement starting within ~0.5 s would rewind to it
        // and silently undo the reset.
        lookBack.removeAll()
        beforeMotion = nil
    }

    /// Abandon the rest of the current movement (it's implausible); keep tracking its rotation so the
    /// end-of-movement rules still apply.
    /// Abandon the rest of the current movement (too long or implausible to integrate) and go back to
    /// where you were *before* it began. Never to zero: continuous small movements while you work
    /// (typing, reading, talking) used to erase a slouch this way and report "good posture".
    private mutating func discardCurrentMotion() {
        if let s = beforeMotion {
            upFilter = s.up
            forwardFilter = s.fwd
            upFilter.zeroVelocity(sigma: 1e-4)
            forwardFilter.zeroVelocity(sigma: 1e-4)
        }
        discardMotion = true
    }

    /// Keep your current head position when switching to another calibration (e.g. the other AirPod).
    mutating func carryOverPosition(from other: PostureEstimator) {
        upFilter = other.upFilter
        forwardFilter = other.forwardFilter
    }

    /// - Parameters:
    ///   - translational: device-frame acceleration with gravity *and* the earbud's swing removed, m/s².
    ///   - omega: device-frame rotation rate, rad/s (sign-corrected).
    mutating func ingest(gravity: SIMD3<Double>, translational a: SIMD3<Double>, omega: SIMD3<Double>, dt: Double) {
        let g = simd_normalize(gravity)
        var fh = calibration.forward - simd_dot(calibration.forward, g) * g     // forward, projected horizontal
        guard simd_length(fh) > 0.2 else { return }
        fh = simd_normalize(fh)
        let aUp = -simd_dot(a, g), aFwd = simd_dot(a, fh)
        let w = simd_length(omega)

        // Less trust in acceleration while the head is rotating fast (residual swing / fusion error).
        let noise = 0.05 + 0.25 * min(w, 3)

        lowPassed += 0.3 * (a - lowPassed)
        let wasStill = stillness.isStill
        let movementEnded = stillness.update(accelMagnitude: simd_length(lowPassed), rotationRate: w, dt: dt)

        if wasStill && !stillness.isStill {
            beforeMotion = (lookBack.first?.up ?? upFilter, lookBack.first?.fwd ?? forwardFilter)
        }
        if wasStill && !stillness.isStill, let first = lookBack.first {
            upFilter = first.up
            forwardFilter = first.fwd
            for s in lookBack {
                upFilter.predict(accel: s.aUp, dt: s.dt, accelNoise: s.noise)
                forwardFilter.predict(accel: s.aFwd, dt: s.dt, accelNoise: s.noise)
            }
        }
        if stillness.isStill {
            lookBack.append((upFilter, forwardFilter, aUp, aFwd, noise, dt))
            while lookBack.map(\.dt).reduce(0, +) > Self.lookBackTime { lookBack.removeFirst() }
        } else {
            lookBack.removeAll()
        }
        if !discardMotion {
            upFilter.predict(accel: aUp, dt: dt, accelNoise: noise)
            forwardFilter.predict(accel: aFwd, dt: dt, accelNoise: noise)
        }

        if stillness.isStill {
            upFilter.zeroVelocity()
            forwardFilter.zeroVelocity()
            if movementEnded { endOfMovement(gravity: g) }
            discardMotion = false
            beforeMotion = nil
            relaxTowardNeutral(gravity: g, dt: dt)
        } else {
            if motionStartGravity == nil {
                motionStartGravity = g; motionRotation = 0; motionTime = 0
                motionStartTilt = angle(g, calibration.neutralGravity)
            }
            motionRotation = max(motionRotation, angle(g, motionStartGravity!))
            motionTime += dt
            if motionTime > Self.maxMotion { discardCurrentMotion() }   // long continuous motion: position unknowable
        }
        if outOfRange {
            if stillness.isStill {
                resetFilters()
            } else if motionTime < Self.maxMotion, abs(shiftUp) > 0.10 {
                // A quick, large rise or drop is you standing up or sitting down (vertical moves like that
                // are measured reliably): that's a posture break, so start fresh and ignore the rest.
                resetFilters()
                discardMotion = true
            } else {
                discardCurrentMotion()       // implausible drift: back to the position before the movement
            }
        }
    }

    private mutating func endOfMovement(gravity g: SIMD3<Double>) {
        defer { motionStartGravity = nil }
        // Sitting back up after slouching with your head tipped (e.g. after an alert): the head starts
        // clearly tilted, rotates, and ends near your calibrated angle. Fast rotation confuses the
        // accelerometer, so snap position to neutral rather than trust the integration.
        // (A slump that *ends* with your eyes level on the screen started near neutral, so it doesn't
        // match: resetting there would hide exactly the forward-head slouch we're looking for.)
        if motionStartTilt > 12 * .pi / 180, motionRotation > 7 * .pi / 180,
           angle(g, calibration.neutralGravity) < 9 * .pi / 180 {
            resetFilters()
            return
        }
        // Anything over 30 cm isn't a posture shift (standing up, reaching for something).
        if (shiftUp * shiftUp + shiftForward * shiftForward).squareRoot() > 0.30 { resetFilters() }
    }

    /// While your head is level, very slowly pull any leftover offset back to zero (~8 hour time constant),
    /// a last-resort bound on long-term error. It must be slow: a forward-head slouch with level eyes looks
    /// exactly like this, and fading it in under a minute caused false "good posture" readings.
    private mutating func relaxTowardNeutral(gravity g: SIMD3<Double>, dt: Double) {
        guard angle(g, calibration.neutralGravity) < 6 * .pi / 180 else { return }
        for i in 0..<2 {
            var f = i == 0 ? upFilter : forwardFilter
            let p = max(f.sigma * f.sigma, 1e-8)
            f.observePosition(0, variance: p * Self.relaxSeconds / dt)
            if i == 0 { upFilter = f } else { forwardFilter = f }
        }
    }

    /// Beyond what a posture shift can be: a movement went wrong or you got up.
    private var outOfRange: Bool {
        shiftUp > 0.10 || shiftUp < -0.20 || shiftForward > 0.20 || shiftForward < -0.10
    }

    private func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }

    func reading(gravity: SIMD3<Double>) -> PostureReading {
        let g = simd_normalize(gravity)
        let tilt = angle(g, calibration.neutralGravity)
        let pitch = asin(min(1, max(-1, simd_dot(g, calibration.forward))))
        let roll = asin(min(1, max(-1, simd_dot(g, calibration.left))))
        let fwd = Self.neckLever * sin(pitch) + shiftForward
        let drop = Self.neckLever * (1 - cos(tilt)) - shiftUp
        return PostureReading(tilt: tilt * 180 / .pi, pitch: pitch * 180 / .pi, roll: roll * 180 / .pi,
                              forwardCM: fwd * 100, dropCM: drop * 100,
                              forwardSigmaCM: forwardFilter.sigma * 100, dropSigmaCM: upFilter.sigma * 100)
    }
}
