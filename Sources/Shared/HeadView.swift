import CoreMotion
import SceneKit
import SwiftUI

/// Realistic mannequin bust (3D head scan) rigged with a neck joint.
/// The head rotates with your AirPods and shifts forward/down with your estimated head position.
@MainActor
final class HeadScene {
    // AirPods → model axis directions.
    private let pitchSign: Float = -1, yawSign: Float = -1, rollSign: Float = -1

    /// Model units per centimetre (the scan's head is ~4.7 units from crown to chin ≈ 23 cm).
    nonisolated static let unitsPerCM: Float = 0.205
    /// Lower-neck joint (base of the neck) and skull-base joint, in model space.
    // Joints sit toward the back of the neck, where the spine is: a neck bends around its vertebrae,
    // not its middle, and placing them centrally dragged the back-of-neck skin over a long lever.
    nonisolated static let neckBase = SIMD3<Float>(0, -1.35, -0.95)
    nonisolated static let skullBase = SIMD3<Float>(0, 0.35, -0.75)
    /// Centre line of the neck column (for deciding which skin belongs to the neck rather than the shoulders).
    nonisolated static let neckAxisZ: Float = -0.35

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let rootBone = SCNNode()
    private let neckBone = SCNNode()
    private let headBone = SCNNode()
    private let skin = SCNMaterial()
    private var reference: CMAttitude?
    /// Smooths head motion every frame (see HeadAnimator).
    let animator: HeadAnimator
    private let eulerHelper = SCNNode()

    // Warm clay rather than stark white: reads as a friendly sculpture, not a mannequin in a store window.
    private static let ivory = PlatformColor.rgb(0.86, 0.79, 0.72)
    private static let warm = PlatformColor.rgb(0.98, 0.62, 0.42)

    private var styleNodes: [MannequinStyle: [SCNNode]] = [:]

    init(resources: Bundle = .main, style: MannequinStyle = .male) {
        animator = HeadAnimator(root: rootBone, neck: neckBone, head: headBone, neckLength: simd_length(Self.skullBase - Self.neckBase))
        // Soft, matte clay finish.
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = Self.ivory
        skin.roughness.contents = 0.78
        skin.metalness.contents = 0.0
        skin.clearCoat.contents = 0.0

        // Glossy, moulded dark-grey hair.
        let hair = SCNMaterial()
        hair.lightingModel = .physicallyBased
        hair.diffuse.contents = PlatformColor(white: 0.21, alpha: 1)
        hair.roughness.contents = 0.5
        hair.metalness.contents = 0.0
        hair.clearCoat.contents = 0.18
        hair.clearCoatRoughness.contents = 0.45
        hair.isDoubleSided = true

        let bust = SCNNode()
        scene.rootNode.addChildNode(bust)
        bust.addChildNode(rootBone)
        neckBone.simdPosition = Self.neckBase
        rootBone.addChildNode(neckBone)
        headBone.simdPosition = Self.skullBase - Self.neckBase
        neckBone.addChildNode(headBone)

        if let url = resources.url(forResource: "HeadNormal", withExtension: "jpg") {
            skin.normal.contents = url
            skin.normal.intensity = 0.12      // just a hint of sculpted form, no skin detail
        }

        // Head scan bust: shoulders stay put, head follows the head bone, neck blends between.
        let headSpace = SCNNode()
        headSpace.simdPosition = -Self.skullBase
        headBone.addChildNode(headSpace)
        if let url = resources.url(forResource: "Head", withExtension: "glb") {
            for s in MannequinStyle.allCases {
                guard let raw = try? GLBLoader.loadGeometry(url: url, transform: s == .female ? HairBuilder.femaleMorph : nil)
                else { continue }
                // Gentle overall smoothing, then extra softening around the (closed, scanned) eyes so the
                // face reads as a calm sculpture instead of a realistic sleeping face.
                let soft = MeshSmoothing.smoothed(raw, iterations: 30, keepBelowY: -3.8)
                let geometry = MeshSmoothing.smoothed(soft, iterations: 45, keepBelowY: -3.8, weight: Self.eyeRegion)
                geometry.firstMaterial = skin
                let mesh = SCNNode(geometry: geometry)
                mesh.skinner = Self.makeSkinner(geometry, bones: [rootBone, neckBone, headBone],
                                                bindPositions: [.zero, Self.neckBase, Self.skullBase],
                                                weights: Self.skinWeights)
                bust.addChildNode(mesh)

                // Hair is rigid on the head bone (the head region is fully weighted to it).
                let hairNode = HairBuilder.hairNodes(scalp: geometry.positions, style: s, material: hair)
                headSpace.addChildNode(hairNode)
                styleNodes[s] = [mesh, hairNode]
            }
        }
        setStyle(style)

        // Purely decorative: a faint floor + back-wall grid for a sense of space.
        scene.rootNode.addChildNode(Self.spatialGrid())

        // Camera & lighting.
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 33
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.screenSpaceAmbientOcclusionIntensity = 0.25   // light touch: deep eye shadows look eerie
        cameraNode.camera?.screenSpaceAmbientOcclusionRadius = 0.5
        // Three-quarter side view: friendlier than face-on, and the best angle to see forward-head posture.
        cameraNode.position = SCNVector3(14.5, 3.2, 13.0)
        cameraNode.look(at: SCNVector3(0, -0.1, 0.9))       // room in front of the face for forward lean
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.25

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.light?.color = PlatformColor.rgb(1.0, 0.95, 0.88)        // warm, like late-afternoon light
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 9
        key.light?.shadowSampleCount = 12
        key.light?.shadowColor = PlatformColor(white: 0, alpha: 0.2)
        key.eulerAngles = SCNVector3(-0.7, 0.75, 0)
        scene.rootNode.addChildNode(key)

        // Soft warm fill from the camera side lifts the shadows on the face.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 380
        fill.light?.color = PlatformColor.rgb(1.0, 0.9, 0.82)
        fill.eulerAngles = SCNVector3(-0.15, 1.05, 0)
        scene.rootNode.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 500
        rim.light?.color = PlatformColor.rgb(0.85, 0.9, 1)
        rim.eulerAngles = SCNVector3(-0.3, .pi + 0.6, 0)
        scene.rootNode.addChildNode(rim)
    }

    /// Where to soften the scan: both eye sockets (front of the face, around eye height).
    nonisolated static func eyeRegion(_ p: SIMD3<Float>) -> Float {
        guard p.z > 1.45 else { return 0 }
        let dy = (p.y - 1.72) / 0.24
        let dx = (abs(p.x) - 0.6) / 0.36
        return exp(-(dx * dx + dy * dy))
    }

    // MARK: Driving the model

    /// Points the head from the AirPods reading.
    ///
    /// With a calibration, forward/back and side tilt come from gravity relative to your *saved* neutral
    /// pose, which is absolute and survives restarts. Only the left/right turn is measured from launch
    /// (AirPods have no lasting reference for which way is "forward"). Previously everything was relative
    /// to the first reading after launch, whatever pose you were in while the sensor was still settling,
    /// so the model could start, and stay, tilted to one side.
    func update(_ attitude: CMAttitude, gravity: SIMD3<Double>, calibration: HeadCalibration?) {
        guard let a = attitude.copy() as? CMAttitude else { return }
        if reference == nil { reference = a.copy() as? CMAttitude }
        if let r = reference { a.multiply(byInverseOf: r) }
        guard let cal = calibration else {
            setPose(pitch: Float(a.pitch), yaw: Float(a.yaw), roll: Float(a.roll))
            return
        }
        animator.setTarget(rotation: Self.headRotation(gravity: gravity, calibration: cal, yaw: yawSign * Float(a.yaw)))
    }

    /// Head orientation in model space (x = model's left, y = up, z = facing) from gravity in the AirPods
    /// frame and the calibrated head axes, plus a turn `yaw` (radians) about the vertical.
    nonisolated static func headRotation(gravity: SIMD3<Double>, calibration cal: HeadCalibration, yaw: Float) -> simd_quatf {
        let g = simd_normalize(gravity)
        // Gravity as seen from the head, in model axes. Upright it points straight down (0, −1, 0).
        let seen = simd_normalize(SIMD3<Float>(Float(simd_dot(g, cal.left)), Float(simd_dot(g, cal.up)), Float(simd_dot(g, cal.forward))))
        // The head's tilt is the rotation that turns "down" (in the head's frame) back into world down.
        let tilt = simd_quatf(from: seen, to: SIMD3(0, -1, 0))
        return simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * tilt
    }

    /// Sets where the head should point; the animator glides there. `immediate` snaps (e.g. for snapshots).
    func setPose(pitch: Float, yaw: Float, roll: Float, immediate: Bool = false) {
        // Let SceneKit convert its own Euler convention to a quaternion, so smoothing can blend rotations.
        eulerHelper.eulerAngles = SCNVector3(pitchSign * pitch, yawSign * yaw, rollSign * roll)
        animator.setTarget(rotation: eulerHelper.simdOrientation, immediate: immediate)
    }

    /// Estimated head translation relative to calibrated neutral, in cm (forward +, drop +).
    func setOffset(forwardCM: Double, dropCM: Double, immediate: Bool = false) {
        // Shown by bending the neck forward (see HeadAnimator); the drop follows from the bend.
        let f = Float(max(-4, min(6, forwardCM)))          // beyond ~6 cm the estimate is too uncertain to show
        animator.setTarget(forward: f * Self.unitsPerCM, immediate: immediate)
    }

    func setStyle(_ style: MannequinStyle) {
        for (s, nodes) in styleNodes { nodes.forEach { $0.isHidden = s != style } }
    }

    /// Make the current head orientation the "facing forward" pose.
    func recenter() { reference = nil }

    func setSlouching(_ slouching: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        skin.diffuse.contents = slouching ? Self.warm : Self.ivory
        SCNTransaction.commit()
    }

    // MARK: Background grid

    /// Thin, semi-transparent grid lines on a floor under the bust and a wall behind it.
    /// Lines fade out toward the edges so the grid reads as depth rather than a box.
    static func spatialGrid() -> SCNNode {
        var verts: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = [], idx: [UInt32] = []
        let floorY: Float = -4.05, wallZ: Float = -7.5, half: Float = 14, step: Float = 1
        let center = SIMD3<Float>(0, -1, -2)

        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, major: Bool) {
            let segments = 24                                       // split so the fade is smooth along the line
            for k in 0..<segments {
                let span: SIMD3<Float> = b - a
                let f0: Float = Float(k) / Float(segments), f1: Float = Float(k + 1) / Float(segments)
                let p0: SIMD3<Float> = a + span * f0, p1: SIMD3<Float> = a + span * f1
                for p in [p0, p1] {
                    let fade = max(0, 1 - simd_length(p - center) / 15)
                    let alpha = (major ? 0.32 : 0.14) * fade * fade
                    idx.append(UInt32(verts.count))
                    verts.append(p)
                    colors.append(SIMD4(0.62, 0.78, 1.0, alpha))
                }
            }
        }
        var i: Float = -half
        while i <= half {
            let major = Int(i.rounded()) % 4 == 0
            line(SIMD3(i, floorY, 7), SIMD3(i, floorY, wallZ), major: major)                            // floor, front→back
            let z = wallZ + (i + half) * 0.55                                                           // floor, left→right
            if z <= 7 { line(SIMD3(-half, floorY, z), SIMD3(half, floorY, z), major: major) }
            if i >= floorY - 1 && i <= 12 {
                line(SIMD3(-half, i, wallZ), SIMD3(half, i, wallZ), major: major)                      // wall, horizontal
            }
            line(SIMD3(i, floorY, wallZ), SIMD3(i, 12, wallZ), major: major)                            // wall, vertical
            i += step
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: verts.map { SCNVector3($0) }),
                      SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                        componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)],
            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = PlatformColor.white
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        geometry.firstMaterial = m
        let node = SCNNode(geometry: geometry)
        node.name = "spatialGrid"
        node.renderingOrder = -10
        node.castsShadow = false
        return node
    }

    // MARK: Rigging

    /// Two-bone skin: shoulders stay put, the head follows `head`, and the neck blends between them.
    /// Shoulders / neck / head weights for one vertex of the scan.
    /// - Shoulders → neck: across the base of the neck (and only the neck column below the jaw line).
    /// - Neck → head: along a sloped line: at the back it's the base of the skull; at the front it's
    ///   below the chin, so the jaw and chin move with the head and the throat bends with the neck.
    nonisolated static func skinWeights(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let radial = (p.x * p.x + (p.z - neckAxisZ) * (p.z - neckAxisZ)).squareRoot()
        let column = 1 - smoothstep(1.2, 2.2, radial)
        // Below the jaw line only the neck column lifts; the shoulders stay. That restriction fades in
        // smoothly with depth (a hard cut-off here tore the skin at the back of the neck when it bent).
        let restrict = smoothstep(-0.9, -1.6, p.y)
        let lifted = smoothstep(-1.9, -0.95, p.y) * (1 + (column - 1) * restrict)   // moves with neck or head
        let boundary = 0.35 + (-1.0 - 0.35) * smoothstep(-0.9, 0.9, p.z)
        // Wide handover band, widest at the throat, so neck/head bends spread over the skin instead of
        // concentrating in a crease under the chin.
        let band = 0.55 + 0.35 * smoothstep(0.0, 0.9, p.z)
        let headShare = smoothstep(boundary - band, boundary + band, p.y)
        let head = lifted * headShare, neck = lifted * (1 - headShare)
        return SIMD3(1 - lifted, neck, head)
    }

    /// Three-bone skin (shoulders, lower neck, skull base) with per-vertex weights.
    private static func makeSkinner(_ geometry: SCNGeometry, bones: [SCNNode], bindPositions: [SIMD3<Float>],
                                    weights: (SIMD3<Float>) -> SIMD3<Float>) -> SCNSkinner {
        let src = geometry.sources(for: .vertex)[0]
        let n = src.vectorCount
        var w = [Float](), idx = [UInt16]()
        w.reserveCapacity(n * 3)
        idx.reserveCapacity(n * 3)
        src.data.withUnsafeBytes { b in
            for i in 0..<n {
                let base = src.dataOffset + i * src.dataStride
                let p = SIMD3(b.load(fromByteOffset: base, as: Float.self),
                              b.load(fromByteOffset: base + 4, as: Float.self),
                              b.load(fromByteOffset: base + 8, as: Float.self))
                let v = weights(p)
                w += [v.x, v.y, v.z]
                idx += [0, 1, 2]
            }
        }
        let wData = w.withUnsafeBufferPointer { Data(buffer: $0) }
        let iData = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        let weightSrc = SCNGeometrySource(data: wData, semantic: .boneWeights, vectorCount: n, usesFloatComponents: true,
                                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let indexSrc = SCNGeometrySource(data: iData, semantic: .boneIndices, vectorCount: n, usesFloatComponents: false,
                                         componentsPerVector: 3, bytesPerComponent: 2, dataOffset: 0, dataStride: 6)
        let skinner = SCNSkinner(baseGeometry: geometry, bones: bones,
                                 boneInverseBindTransforms: bindPositions.map { NSValue(scnMatrix4: scnTranslation(-$0)) },
                                 boneWeights: weightSrc, boneIndices: indexSrc)
        skinner.skeleton = bones[0]
        return skinner
    }

    nonisolated private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = Swift.min(1, Swift.max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Soft photo-studio gradient used for image-based lighting / reflections.
    private static func studioEnvironment() -> CGImage? {
        let w = 512, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.18, alpha: 1)] as CFArray,
                                  locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 90, y: 170, width: 110, height: 50), cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 330, y: 160, width: 70, height: 40), cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }
}

struct HeadView: NSViewRepresentable {
    let headScene: HeadScene
    func makeNSView(context: Context) -> SCNView { Self.makeView(headScene) }
    func updateNSView(_ nsView: SCNView, context: Context) {}
}

extension HeadView {
    @MainActor static func makeView(_ headScene: HeadScene) -> SCNView {
        let v = SCNView()
        v.scene = headScene.scene
        v.pointOfView = headScene.cameraNode
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.isPlaying = true
        v.delegate = headScene.animator          // per-frame smoothing of head motion
        v.preferredFramesPerSecond = 60
        return v
    }
}
