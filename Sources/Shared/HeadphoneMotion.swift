import CoreMotion
import Foundation
import simd

/// Streams AirPods head motion (CMHeadphoneMotionManager, ~25 Hz).
@MainActor
final class HeadphoneMotion: NSObject, CMHeadphoneMotionManagerDelegate {
    struct Sample {
        var gravity: SIMD3<Double>        // device frame, unit-ish
        var userAccel: SIMD3<Double>      // device frame, in g, physical sign (+ = direction the head accelerates)
        var attitude: CMAttitude
        var rotation: simd_double3x3      // attitude rotation matrix
        var rotationRate: SIMD3<Double>   // rad/s, device frame (sign verified downstream by GyroSignVoter)
        var earbud: Earbud                // which AirPod the data comes from
        var dt: Double
    }

    private let manager = CMHeadphoneMotionManager()
    private var lastTimestamp: TimeInterval?
    private var dropoutPending = false
    private(set) var lastSampleDate: Date?
    var onSample: ((Sample) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnect: (() -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var isStreaming: Bool {
        guard let d = lastSampleDate else { return false }
        return Date().timeIntervalSince(d) < 3
    }

    /// Raw time step for a sample (not capped: the spike filter uses long steps to detect dropped samples).
    /// The first sample after a disconnect is reported as a long step, so it's treated as a gap rather than
    /// as if it directly followed the last sample before the dropout.
    nonisolated static func timeStep(previous: TimeInterval?, now: TimeInterval, afterDropout: Bool) -> Double {
        if afterDropout { return 1.0 }
        guard let previous else { return 0.04 }
        return max(now - previous, 0.001)
    }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.delegate = self
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.ingest(motion) }
        }
    }

    private func ingest(_ m: CMDeviceMotion) {
        let dt = Self.timeStep(previous: lastTimestamp, now: m.timestamp, afterDropout: dropoutPending)
        dropoutPending = false
        lastTimestamp = m.timestamp
        lastSampleDate = Date()
        onSample?(Sample(
            gravity: SIMD3(m.gravity.x, m.gravity.y, m.gravity.z),
            // Core Motion reports acceleration with Apple's sign convention (at rest the accelerometer
            // reads −1 g along "down"), so userAcceleration points OPPOSITE to the real kinematic
            // acceleration of your head. Flip it once here so everything downstream is physical.
            userAccel: -SIMD3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
            attitude: m.attitude,
            rotation: { let r = m.attitude.rotationMatrix
                return simd_double3x3(rows: [SIMD3(r.m11, r.m12, r.m13), SIMD3(r.m21, r.m22, r.m23), SIMD3(r.m31, r.m32, r.m33)]) }(),
            rotationRate: SIMD3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
            earbud: Self.earbud(m),
            dt: dt))
    }

    private static func earbud(_ m: CMDeviceMotion) -> Earbud {
        guard m.responds(to: NSSelectorFromString("sensorLocation")) else { return .unknown }
        switch m.sensorLocation {
        case .headphoneLeft: return .left
        case .headphoneRight: return .right
        default: return .unknown
        }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.onConnect?() }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.lastSampleDate = nil
            self.lastTimestamp = nil
            self.dropoutPending = true
            self.onDisconnect?()
        }
    }
}
