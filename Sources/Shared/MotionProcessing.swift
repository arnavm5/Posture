import Foundation
import simd

// MARK: - Kalman filter with zero-velocity updates

/// One axis of position tracking: state = [position, velocity, accelerometer bias].
///
/// Acceleration drives the prediction. Whenever you're known to be still, a zero-velocity
/// measurement ("ZUPT") pins velocity to 0, which, through the filter's cross-covariances, also
/// corrects position and teaches it the accelerometer bias. The position variance doubles as an
/// honest confidence estimate (`sigma`).
struct ZUPTKalman {
    private(set) var x = SIMD3<Double>.zero          // p (m), v (m/s), b (m/s²)
    private(set) var P = simd_double3x3(diagonal: SIMD3(1e-6, 1e-4, 0.05 * 0.05))

    var position: Double { x.x }
    var velocity: Double { x.y }
    var bias: Double { x.z }
    /// 1-sigma position uncertainty, metres.
    var sigma: Double { max(0, P[0][0]).squareRoot() }

    /// - Parameters:
    ///   - accelNoise: white-noise std of the measured acceleration (m/s²). Raise it when the signal is less trustworthy.
    ///   - biasWalk: random-walk std of the bias (m/s² per √s).
    mutating func predict(accel: Double, dt: Double, accelNoise: Double = 0.05, biasWalk: Double = 0.002) {
        let a = accel - x.z
        x.x += x.y * dt + 0.5 * a * dt * dt
        x.y += a * dt
        let F = simd_double3x3(rows: [SIMD3(1, dt, -0.5 * dt * dt), SIMD3(0, 1, -dt), SIMD3(0, 0, 1)])
        let G = SIMD3(0.5 * dt * dt, dt, 0)
        var Q = outer(G, G) * (accelNoise * accelNoise)
        Q[2][2] += biasWalk * biasWalk * dt
        P = F * P * F.transpose + Q
    }

    mutating func zeroVelocity(sigma: Double = 0.005) {
        update(h: SIMD3(0, 1, 0), z: 0, variance: sigma * sigma)
    }

    mutating func observePosition(_ z: Double, variance: Double) {
        update(h: SIMD3(1, 0, 0), z: z, variance: variance)
    }

    /// Hard reset of position and velocity (keeps the learned bias).
    mutating func resetPosition() {
        x.x = 0; x.y = 0
        P[0][0] = 1e-6; P[1][1] = 1e-4
        P[0][1] = 0; P[1][0] = 0; P[0][2] = 0; P[2][0] = 0; P[1][2] = 0; P[2][1] = 0
    }

    private mutating func update(h: SIMD3<Double>, z: Double, variance: Double) {
        let Ph = P * h
        let s = simd_dot(h, Ph) + variance
        guard s > 0 else { return }
        let k = Ph / s
        x += k * (z - simd_dot(h, x))
        P -= outer(k, Ph)
        P = (P + P.transpose) * 0.5                   // keep it symmetric
    }
}

/// a ⊗ b
func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> simd_double3x3 {
    simd_double3x3(columns: (a * b.x, a * b.y, a * b.z))
}

func skew(_ v: SIMD3<Double>) -> simd_double3x3 {
    simd_double3x3(rows: [SIMD3(0, -v.z, v.y), SIMD3(v.z, 0, -v.x), SIMD3(-v.y, v.x, 0)])
}

// MARK: - Stillness

/// Decides when the head is genuinely still, against an adaptive noise floor learned while still.
struct StillnessDetector {
    private(set) var isStill = true
    private(set) var noiseFloor = 0.03           // m/s²
    private var energy = 0.0
    private var quietFor = 0.0

    static let quietTime = 0.3
    static let maxStillRotation = 0.25           // rad/s
    static let moveRotation = 0.6

    var startThreshold: Double { max(0.10, 3.5 * noiseFloor) }
    var quietThreshold: Double { max(0.045, 1.8 * noiseFloor) }

    /// Returns `true` on the sample where a movement ends (moving → still).
    @discardableResult
    mutating func update(accelMagnitude: Double, rotationRate: Double, dt: Double) -> Bool {
        energy += 0.3 * (accelMagnitude - energy)
        if isStill {
            noiseFloor += 0.01 * (energy - noiseFloor)
            if energy > startThreshold || rotationRate > Self.moveRotation {
                isStill = false
                quietFor = 0
            }
            return false
        }
        quietFor = (energy < quietThreshold && rotationRate < Self.maxStillRotation) ? quietFor + dt : 0
        if quietFor >= Self.quietTime {
            isStill = true
            return true
        }
        return false
    }
}

// MARK: - Gyro sign

/// Confirms the sign convention of the rotation rate from the data itself:
/// gravity is fixed in the world, so in the device frame it must move as  dg/dt = g × ω.
/// Evidence from fast rotations is accumulated and the sign locks once it's unambiguous.
struct GyroSignVoter {
    private(set) var sign: Double?
    private var votes = 0.0

    var effectiveSign: Double { sign ?? 1 }

    mutating func observe(previousGravity g0: SIMD3<Double>, gravity g1: SIMD3<Double>, omega: SIMD3<Double>, dt: Double) {
        guard sign == nil, simd_length(omega) > 0.5 else { return }
        let a = simd_normalize(g0), b = simd_normalize(g1)
        let observed = b - a
        let predicted = simd_cross(a, omega) * dt
        let n = simd_length(observed) * simd_length(predicted)
        guard n > 1e-9 else { return }
        votes += simd_dot(observed, predicted) / n           // cosine: +1 agrees, −1 opposite
        if abs(votes) > 10 { sign = votes > 0 ? 1 : -1 }
    }
}

// MARK: - Lever-arm compensation

/// What one motion sample looks like after preprocessing (delayed by one sample so the angular
/// acceleration can use a centred difference).
struct HeadKinematics {
    var gravity: SIMD3<Double>          // device frame, unit-ish
    var accel: SIMD3<Double>            // measured earbud acceleration, m/s², device frame
    var omega: SIMD3<Double>            // rad/s, device frame, sign-corrected
    var alpha: SIMD3<Double>            // rad/s², device frame
    var translational: SIMD3<Double>    // accel with the earbud's swing around the neck removed
    var rotation: simd_double3x3        // attitude rotation matrix (passed through)
    var dt: Double
}

/// The AirPods sit several centimetres from the point the head pivots on, so every nod or turn
/// swings the earbud around that point and the accelerometer sees it as movement:
///     a_earbud = a_head + α × r + ω × (ω × r)
/// With the lever arm r (from calibration) and the gyroscope, that swing is subtracted out.
struct LeverArmCompensator {
    var lever: SIMD3<Double> = .zero
    private(set) var gyro = GyroSignVoter()
    private var history: [(g: SIMD3<Double>, a: SIMD3<Double>, w: SIMD3<Double>, rot: simd_double3x3, dt: Double)] = []

    /// Forget recent samples (after a gap, so angular acceleration isn't computed across it).
    mutating func reset() { history = [] }

    /// - Parameters: accel in m/s² (physical sign), omega in rad/s as reported.
    mutating func step(gravity: SIMD3<Double>, accel: SIMD3<Double>, omega rawOmega: SIMD3<Double>,
                       rotation: simd_double3x3, dt: Double) -> HeadKinematics? {
        if let last = history.last {
            gyro.observe(previousGravity: last.g, gravity: gravity, omega: rawOmega * gyro.effectiveSign, dt: dt)
        }
        history.append((gravity, accel, rawOmega, rotation, dt))
        if history.count > 3 { history.removeFirst() }
        guard history.count == 3 else { return nil }

        let s = gyro.effectiveSign
        let (prev, mid, next) = (history[0], history[1], history[2])
        let w = mid.w * s
        let alpha = (next.w - prev.w) * s / max(1e-3, mid.dt + next.dt)
        let swing = simd_cross(alpha, lever) + simd_cross(w, simd_cross(w, lever))
        return HeadKinematics(gravity: mid.g, accel: mid.a, omega: w, alpha: alpha,
                              translational: mid.a - swing, rotation: mid.rot, dt: mid.dt)
    }
}

/// Least-squares fit of the lever arm r from samples where the head rotates about a (roughly) fixed
/// pivot:  a = ([α]× + [ω]×[ω]×) r.  A small ridge term pulls toward a sensible default.
struct LeverArmFit {
    private var A = simd_double3x3(0)
    private var b = SIMD3<Double>.zero
    private(set) var informativeSamples = 0
    private var residuals: [(M: simd_double3x3, a: SIMD3<Double>)] = []

    mutating func add(_ k: HeadKinematics) {
        let w = simd_length(k.omega), al = simd_length(k.alpha)
        guard w > 0.6 || al > 3 else { return }
        guard w < 8, al < 40 else { return }          // glitches (dropped samples, bumps) aren't head rotation
        let M = skew(k.alpha) + skew(k.omega) * skew(k.omega)
        A += M.transpose * M
        b += M.transpose * k.accel
        residuals.append((M, k.accel))
        informativeSamples += 1
    }

    /// Returns the fitted lever arm (m), or nil if there wasn't enough rotation or the result is implausible.
    func solve(prior: SIMD3<Double>, ridge: Double = 5) -> (lever: SIMD3<Double>, rmsResidual: Double)? {
        guard informativeSamples >= 15 else { return nil }
        let reg = A + simd_double3x3(diagonal: SIMD3(repeating: ridge))
        guard abs(reg.determinant) > 1e-9 else { return nil }
        let r = reg.inverse * (b + prior * ridge)
        guard (0.02...0.20).contains(simd_length(r)) else { return nil }
        let rms = (residuals.map { simd_length_squared($0.a - $0.M * r) }.reduce(0, +) / Double(residuals.count)).squareRoot()
        return (r, rms)
    }
}

// MARK: - Spike and gap filtering (raw stream)

/// One cleaned motion sample (physical units).
struct MotionSample {
    var gravity: SIMD3<Double>          // device frame, unit length
    var accel: SIMD3<Double>            // m/s², device frame, physical sign
    var omega: SIMD3<Double>            // rad/s, device frame
    var rotation: simd_double3x3
    var dt: Double
    /// Samples were dropped just before this one (Bluetooth hiccup): don't difference or integrate across it.
    var gap = false
}

/// Removes one-sample glitches from the raw AirPods stream and flags dropped-sample gaps.
///
/// A reading is a spike when it's far from the average of its two neighbours *while those neighbours
/// agree with each other*. A single corrupted packet looks like that; a real movement doesn't (its
/// next sample is also different), so genuine motion passes through untouched. Spikes are replaced by
/// the neighbours' average. This needs one sample of look-ahead, so output is delayed by one sample
/// (~40 ms).
struct SpikeFilter {
    static let accelSpike = 1.5                  // m/s²
    static let omegaSpike = 1.5                  // rad/s
    static let gravitySpike = 10 * Double.pi / 180
    static let gapAfter = 0.25                   // s without data = dropped samples
    static let nominalDt = 0.04

    private var window: [MotionSample] = []
    private(set) var spikesRemoved = 0
    private(set) var gaps = 0

    mutating func reset() { window = [] }

    /// Feed one raw sample; returns the cleaned previous sample (nil while filling up).
    mutating func push(_ raw: MotionSample) -> MotionSample? {
        var s = raw
        if s.dt > Self.gapAfter {
            s.gap = true
            s.dt = Self.nominalDt
            gaps += 1
        }
        s.dt = min(max(s.dt, 0.001), 0.1)
        s.gravity = simd_normalize(s.gravity)
        window.append(s)
        if window.count > 3 { window.removeFirst() }
        guard window.count == 3 else { return nil }

        var mid = window[1]
        let prev = window[0], next = window[2]
        if !mid.gap && !next.gap {
            mid.accel = fix(prev.accel, mid.accel, next.accel, limit: Self.accelSpike)
            mid.omega = fix(prev.omega, mid.omega, next.omega, limit: Self.omegaSpike)
            let avg = simd_normalize(prev.gravity + next.gravity)
            if angle(mid.gravity, avg) > Self.gravitySpike, angle(prev.gravity, next.gravity) < Self.gravitySpike / 3 {
                mid.gravity = avg
                spikesRemoved += 1
            }
        }
        window[1] = mid                          // the cleaned value is the next sample's "previous"
        return mid
    }

    private mutating func fix(_ p: SIMD3<Double>, _ m: SIMD3<Double>, _ n: SIMD3<Double>, limit: Double) -> SIMD3<Double> {
        let avg = (p + n) / 2
        let deviation = simd_length(m - avg), neighbourSpread = simd_length(n - p)
        guard deviation > limit, deviation > 4 * neighbourSpread else { return m }
        spikesRemoved += 1
        return avg
    }

    private func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }
}
