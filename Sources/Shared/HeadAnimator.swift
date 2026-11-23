import Foundation
import SceneKit
import simd

/// Smooths and poses the 3D bust's neck and head on SceneKit's render loop.
///
/// **Smoothing.** AirPods report ~25 times a second, but the view draws ~60 times a second. Readings
/// only set a *target*; every frame the pose eases toward it with an adaptive time constant: heavy
/// smoothing when the head is basically still (no jitter), light smoothing when you actually move
/// (no lag). Rotations are blended as quaternions, the forward shift eases more gently still.
///
/// **Posing (no "detached" neck).** The bust has three bones: shoulders, a lower-neck joint and a
/// skull-base joint. A forward head shift is shown by *bending the neck forward* at the lower joint
/// (like real forward-head posture), never by sliding the head over the shoulders, which shears the
/// neck skin. The neck also takes a share of every nod or tilt, and the skull-base joint
/// counter-rotates so the head ends up exactly at the orientation your AirPods report.
final class HeadAnimator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let root: SCNNode?
    private let neck: SCNNode
    private let head: SCNNode
    private let neckLength: Float            // lower-neck joint → skull-base joint, model units

    private var targetRotation = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    private var targetForward: Float = 0     // model units, + = toward the screen
    private(set) var rotation = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    private(set) var forward: Float = 0
    private var lastTime: TimeInterval?

    /// Time constants (seconds).
    static let stillTau: Float = 0.18
    static let movingTau: Float = 0.05
    static let offsetTau: Float = 0.45
    /// Share of the head's own rotation carried by the neck (spreads bends along it, as in a real neck).
    static let neckShare: Float = 0.35
    /// Share of a forward shift shown as the upper body leaning forward (a slouch rounds the upper back,
    /// it isn't all neck). The rest is shown by bending the neck.
    static let leanShare: Float = 0.4
    /// The upper body leans around a point in the mid-back, below the bust (model units).
    static let leanPivot = SIMD3<Float>(0, -6, -1)
    /// Limits on how far the neck bends to show a forward shift.
    static let maxFlex: Float = 0.7, maxExtend: Float = 0.3

    init(root: SCNNode? = nil, neck: SCNNode, head: SCNNode, neckLength: Float) {
        self.root = root
        self.neck = neck
        self.head = head
        self.neckLength = neckLength
    }

    func setTarget(rotation r: simd_quatf, immediate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        // Keep the target on the same hemisphere as the current rotation (shortest path).
        targetRotation = simd_dot(r.vector, rotation.vector) < 0 ? simd_quatf(vector: -r.vector) : r
        if immediate { rotation = targetRotation; apply() }
    }

    /// Forward shift of the head relative to the shoulders, in model units.
    func setTarget(forward f: Float, immediate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        targetForward = f
        if immediate { forward = f; apply() }
    }

    /// How far the neck is bent forward (radians) to show the current forward shift.
    var neckFlex: Float {
        let s = max(-1, min(1, forward * (root == nil ? 1 : 1 - Self.leanShare) / neckLength))
        return max(-Self.maxExtend, min(Self.maxFlex, asin(s)))
    }

    /// Advances the smoothing by `dt` seconds (called every frame; public for testing).
    func advance(dt rawDt: Float) {
        lock.lock(); defer { lock.unlock() }
        let dt = min(max(rawDt, 0), 0.1)
        let d = abs(simd_dot(rotation.vector, targetRotation.vector))
        let gap = 2 * acos(min(1, d))                              // radians between current and target
        let t = min(1, max(0, (gap - 0.025) / (0.26 - 0.025)))     // ~1.5° … 15°
        let blend = t * t * (3 - 2 * t)
        let tau = Self.stillTau + (Self.movingTau - Self.stillTau) * blend
        rotation = simd_slerp(rotation, targetRotation, 1 - exp(-dt / tau))
        forward += (targetForward - forward) * (1 - exp(-dt / Self.offsetTau))
        apply()
    }

    /// How far the upper body leans forward (radians) for the current forward shift.
    var lean: Float {
        guard root != nil else { return 0 }
        let reach = simd_length(SIMD3<Float>(0, 0, 0) - Self.leanPivot)
        return asin(max(-0.3, min(0.3, forward * Self.leanShare / reach)))
    }

    private func apply() {
        let identity = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
        // Upper body: rotate forward around the mid-back pivot.
        let leanRotation = simd_quatf(angle: lean, axis: SIMD3(1, 0, 0))
        if let root {
            root.simdOrientation = leanRotation
            root.simdPosition = Self.leanPivot - leanRotation.act(Self.leanPivot)
        }
        // Neck: bends forward for its share of the shift, plus a share of the head's own rotation (world).
        let flex = simd_quatf(angle: neckFlex, axis: SIMD3(1, 0, 0))     // +x rotation tips the neck forward
        let neckWorld = leanRotation * flex * simd_slerp(identity, rotation, Self.neckShare)
        neck.simdOrientation = leanRotation.inverse * neckWorld
        head.simdOrientation = neckWorld.inverse * rotation               // head ends up exactly at `rotation`
    }

    // MARK: SCNSceneRendererDelegate (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime.map { Float(time - $0) } ?? 0
        lastTime = time
        advance(dt: dt)
    }
}
