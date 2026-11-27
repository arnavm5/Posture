import Foundation

/// Where the upper body is, inferred from the head: how far the trunk leans or curls forward, how far the
/// neck bends relative to the trunk, and how much the head has sunk.
///
/// The AirPods only see the head, but the head sits on a chain: hips → trunk → neck → head. Hunching and
/// leaning in move the base of the neck forward; looking down bends the neck. Telling these apart is
/// exactly what separates a hunch from a glance at the keyboard:
///  - **looking down:** trunk upright, neck bent forward (`neckDeg` > 0).
///  - **hunching / chin poke:** trunk forward, neck bent *back* to keep the eyes on the screen
///    (`trunkDeg` > 0, `neckDeg` < 0).
///  - **slumping:** the head sinks (`sinkCM` > 0) without much tilt.
struct BodyPose: Equatable {
    /// Forward lean/curl of the trunk (hips to base of neck), degrees from your calibrated upright. + = forward.
    var trunkDeg: Double = 0
    /// Neck bend relative to the trunk, degrees. + = bent forward (looking down), − = bent back (chin poke).
    var neckDeg: Double = 0
    /// How much lower the head is than the trunk angle alone explains, cm. + = sunk.
    var sinkCM: Double = 0
}

/// A small Kalman filter that solves for `BodyPose` from 1 Hz head readings.
///
/// Measurements: head pitch (accurate) = trunk + neck; the head's forward position, once the part the
/// head's own tilt explains is removed, is the base of the neck moving on an arc around the hips
/// (noisy: it comes from integrated acceleration); and head height.
/// The prior that makes it work is **time scale**: the trunk changes slowly (hunching creeps in) while
/// the neck changes fast (glances), so a quick head movement is put down to the neck, and only a
/// lasting shift in position to the trunk.
///
/// It uses only pitch, roll, forward and drop, the channels stored with each answer, so features computed
/// live and from saved history are the same.
struct BodyPoseFilter {
    /// Hip joint to the base of the neck, sitting (m).
    static let trunkRadius = 0.50
    static let neckLever = PostureEstimator.neckLever
    /// Measurement noise: pitch (deg), forward position (cm), height (cm).
    static let pitchNoise = 1.0
    static let forwardNoiseCM = 2.5
    static let dropNoiseCM = 2.0
    /// How fast each part can change, per √second: trunk slowly, neck quickly, sinking slowly.
    static let trunkRate = 0.3
    static let neckRate = 4.0
    static let sinkRate = 0.1

    private(set) var pose = BodyPose()
    // Covariance of (trunk, neck), symmetric, and the variance of sink.
    private var p11 = 100.0, p12 = 0.0, p22 = 400.0
    private var sinkVar = 25.0

    /// Feed one reading per second; returns the updated pose.
    @discardableResult
    mutating func add(_ r: PostureReading) -> BodyPose {
        let toRad: Double = .pi / 180
        let toDeg: Double = 180 / .pi
        let leverCM: Double = Self.neckLever * 100
        let radiusCM: Double = Self.trunkRadius * 100

        // Predict: both angles and sink are random walks.
        p11 += Self.trunkRate * Self.trunkRate
        p22 += Self.neckRate * Self.neckRate
        sinkVar += Self.sinkRate * Self.sinkRate

        // 1. Pitch = trunk + neck.
        update(h1: 1, h2: 1, z: r.pitch, noise: Self.pitchNoise * Self.pitchNoise)

        // 2. Forward position not explained by the head's tilt = the neck base on its arc around the hips.
        let pitchRad: Double = r.pitch * toRad
        let neckBaseCM: Double = r.forwardCM - leverCM * sin(pitchRad)
        let ratio: Double = max(-1, min(1, neckBaseCM / radiusCM))
        let trunkSeen: Double = asin(ratio) * toDeg
        let trunkNoise: Double = asin(Self.forwardNoiseCM / radiusCM) * toDeg
        update(h1: 1, h2: 0, z: trunkSeen, noise: trunkNoise * trunkNoise)

        // 3. Sink = height drop beyond what the head's tilt and the trunk's lean explain.
        let rollRad: Double = r.roll * toRad
        let cosTilt: Double = cos(pitchRad) * cos(rollRad)
        let trunkRad: Double = pose.trunkDeg * toRad
        let tiltDrop: Double = leverCM * (1 - cosTilt)
        let leanDrop: Double = radiusCM * (1 - cos(trunkRad))
        let sinkSeen: Double = r.dropCM - tiltDrop - leanDrop
        let noise: Double = Self.dropNoiseCM * Self.dropNoiseCM
        let gain: Double = sinkVar / (sinkVar + noise)
        pose.sinkCM += gain * (sinkSeen - pose.sinkCM)
        sinkVar *= 1 - gain
        return pose
    }

    /// Scalar measurement z = h1·trunk + h2·neck with variance `noise`.
    private mutating func update(h1: Double, h2: Double, z: Double, noise: Double) {
        let ph1: Double = p11 * h1 + p12 * h2      // (P·Hᵀ)₁
        let ph2: Double = p12 * h1 + p22 * h2      // (P·Hᵀ)₂
        let s: Double = h1 * ph1 + h2 * ph2 + noise
        let k1: Double = ph1 / s
        let k2: Double = ph2 / s
        let predicted: Double = h1 * pose.trunkDeg + h2 * pose.neckDeg
        let innovation: Double = z - predicted
        pose.trunkDeg += k1 * innovation
        pose.neckDeg += k2 * innovation
        p11 -= k1 * k1 * s
        p12 -= k1 * k2 * s
        p22 -= k2 * k2 * s
    }

    /// The pose at every second of a trace (the filter run from its start).
    static func poses(_ trace: [PostureReading]) -> [BodyPose] {
        var f = BodyPoseFilter()
        var out: [BodyPose] = []
        out.reserveCapacity(trace.count)
        for r in trace { out.append(f.add(r)) }
        return out
    }
}
