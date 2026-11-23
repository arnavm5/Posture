import Foundation
import simd

/// Display-only tracker: how far your head has moved since you last zeroed it
/// (e.g. standing up shows ≈ +50 cm). It is completely separate from posture detection.
///
/// Pipeline per sample:
///  1. Translational acceleration (earbud swing already removed) → gravity-aligned world frame.
///  2. Low-pass filter: whole-body moves are slow and smooth; typing vibration and head jitter are fast.
///  3. A Kalman filter per world axis, with zero-velocity updates whenever you're still, so the
///     position holds between movements and the accelerometer bias is learned.
///
/// A movement that never settles (walking around for > `maxMotion` s) can't be integrated
/// reliably: it's rolled back to where it started and the readout is marked `approximate`.
struct RelativePositionTracker {
    private(set) var approximate = false
    var moving: Bool { !stillness.isStill }
    var noiseFloor: Double { stillness.noiseFloor }

    var maxMotion = 10.0

    private var filters: [ZUPTKalman] = Array(repeating: ZUPTKalman(), count: 3)
    private var snapshot: [ZUPTKalman]?
    private var stillness = StillnessDetector()
    private var filtered = SIMD3<Double>.zero
    private var motionTime = 0.0
    private var discarding = false               // inside a too-long movement: ignore it until still again
    private var lookBack: [(filters: [ZUPTKalman], a: SIMD3<Double>, dt: Double)] = []
    static let lookBackTime = 0.5

    static let lowPass = 0.25                   // per 25 Hz sample ≈ 1.2 Hz cut-off

    /// World-frame displacement since zeroing, metres. z is up.
    var displacement: SIMD3<Double> { SIMD3(filters[0].position, filters[1].position, filters[2].position) }
    var upCM: Double { displacement.z * 100 }
    var horizontalCM: Double { (displacement.x * displacement.x + displacement.y * displacement.y).squareRoot() * 100 }
    var upSigmaCM: Double { filters[2].sigma * 100 }
    var horizontalSigmaCM: Double { max(filters[0].sigma, filters[1].sigma) * 100 }

    mutating func zero() {
        for i in 0..<3 { filters[i].resetPosition() }
        approximate = false
        snapshot = nil
        motionTime = 0
        lookBack.removeAll()             // a movement right after Zero must not rewind to before it
        discarding = false
    }

    /// - Parameters:
    ///   - worldAccel: translational acceleration in a gravity-aligned world frame (z up), m/s².
    ///   - rotationRate: |ω| in rad/s (used only to judge stillness).
    mutating func ingest(worldAccel a: SIMD3<Double>, rotationRate: Double = 0, dt: Double) {
        filtered += Self.lowPass * (a - filtered)
        let wasStill = stillness.isStill
        stillness.update(accelMagnitude: simd_length(filtered), rotationRate: rotationRate, dt: dt)

        if wasStill && !stillness.isStill {
            // A movement starts. It was only recognised a few samples in, so rewind to just before it
            // and replay those samples without zero-velocity updates.
            if let first = lookBack.first {
                filters = first.filters
                snapshot = filters
                for s in lookBack { for i in 0..<3 { filters[i].predict(accel: s.a[i], dt: s.dt, accelNoise: 0.06) } }
            } else {
                snapshot = filters
            }
            motionTime = 0
        }
        if stillness.isStill {
            lookBack.append((filters, filtered, dt))
            while lookBack.map(\.dt).reduce(0, +) > Self.lookBackTime { lookBack.removeFirst() }
            for i in 0..<3 { filters[i].predict(accel: filtered[i], dt: dt, accelNoise: 0.06); filters[i].zeroVelocity() }
            snapshot = nil
            discarding = false
            return
        }
        lookBack.removeAll()
        if discarding { return }
        for i in 0..<3 { filters[i].predict(accel: filtered[i], dt: dt, accelNoise: 0.06) }
        motionTime += dt
        if motionTime > maxMotion, let s = snapshot {
            filters = s                         // walking / long motion: drop the whole movement rather than guess
            for i in 0..<3 { filters[i].zeroVelocity(sigma: 1e-4) }
            approximate = true
            discarding = true
        }
    }
}

/// Converts device-frame acceleration to a gravity-aligned world frame using CMAttitude's rotation matrix.
///
/// Rather than trusting a particular matrix convention, it checks which of the matrix or its
/// transpose maps world-down onto the measured gravity. While the head is level both look alike,
/// so evidence is accumulated and the convention is locked once it's clear. That way horizontal
/// moves can't flip direction from one sample to the next.
struct WorldFrame {
    private(set) var useTranspose: Bool?       // nil until decided
    private var votes = 0.0

    /// - Parameter accel: device-frame acceleration, m/s². Returns world-frame m/s² (z up).
    mutating func toWorld(_ accel: SIMD3<Double>, gravity: SIMD3<Double>, rotation m: simd_double3x3) -> SIMD3<Double> {
        let g = simd_normalize(gravity)
        let down = SIMD3<Double>(0, 0, -1)
        let evidence = simd_dot(m.transpose * down, g) - simd_dot(m * down, g)   // > 0 favours transpose
        if useTranspose == nil {
            votes += evidence
            if abs(votes) > 2 { useTranspose = votes > 0 }
        }
        let transpose = useTranspose ?? (evidence > 0)
        let deviceFromWorld = transpose ? m.transpose : m
        return deviceFromWorld.transpose * accel
    }

    /// Convenience for acceleration given in g.
    mutating func worldAcceleration(userAccel: SIMD3<Double>, gravity: SIMD3<Double>, rotation m: simd_double3x3) -> SIMD3<Double> {
        toWorld(userAccel * 9.81, gravity: gravity, rotation: m)
    }
}
