import Foundation
import SceneKit
import simd

private func boundingBox(_ node: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    node.enumerateHierarchy { n, _ in
        guard let g = n.geometry else { return }
        for p in g.positions {
            let w = n.simdConvertPosition(p, to: node)
            lo = simd_min(lo, w); hi = simd_max(hi, w)
        }
    }
    return (lo, hi)
}

@MainActor
func modelTests(resources: URL) {
    print("3D model & hair")
    let headURL = resources.appendingPathComponent("Head.glb")

    test("bundled head scan loads with the expected topology") {
        let g = try GLBLoader.loadGeometry(url: headURL)
        expect(g.sources(for: .vertex).first?.vectorCount == 9279, "vertices")
        expect(g.elements.first?.primitiveCount == 17684, "triangles")
        expect(!g.sources(for: .normal).isEmpty && !g.sources(for: .texcoord).isEmpty, "normals + UVs")
    }

    test("load-time transform is applied to every vertex") {
        let plain = try GLBLoader.loadGeometry(url: headURL).positions
        let shifted = try GLBLoader.loadGeometry(url: headURL) { $0 + SIMD3(0, 10, 0) }.positions
        expect(plain.count == shifted.count)
        expect(zip(plain, shifted).allSatisfy { abs($1.y - $0.y - 10) < 1e-4 })
    }

    test("smoothing keeps topology and doesn't move the bust") {
        let raw = try GLBLoader.loadGeometry(url: headURL)
        let smooth = MeshSmoothing.smoothed(raw, iterations: 30, keepBelowY: -3.8)
        let a = raw.positions, b = smooth.positions
        expect(a.count == b.count)
        let meanShift = zip(a, b).map { simd_length($0 - $1) }.reduce(0, +) / Float(a.count)
        expect(meanShift < 0.05, "mean vertex shift \(meanShift)")
    }

    test("female morph slims the jaw and leaves the crown alone") {
        let jaw = HairBuilder.femaleMorph(SIMD3(1.4, 0.6, 1.0))
        expect(jaw.x < 1.4 * 0.95, "jaw x \(jaw.x)")
        let crown = HairBuilder.femaleMorph(SIMD3(0.5, 3.8, 0.2))
        expect(simd_length(crown - SIMD3(0.5, 3.8, 0.2)) < 1e-4, "crown moved")
    }

    test("scalp map never sits below the surface it was built from") {
        let pts = (0..<4000).map { i -> SIMD3<Float> in
            let phi = Float(i) * 2.399963, y = 1 - 2 * (Float(i) + 0.5) / 4000
            let r = (1 - y * y).squareRoot()
            return SIMD3(r * cos(phi), y, r * sin(phi)) * 2
        }
        let map = RadialMap(points: pts, center: .zero)
        for el in stride(from: Float(-1.2), through: 1.2, by: 0.3) {
            for phi in stride(from: -Float.pi, through: .pi, by: 0.5) {
                let r = map.radius(phi: phi, el: el)
                expect(r >= 2.0 && r < 2.12, "radius \(r) at \(phi),\(el)")
            }
        }
    }

    test("hairline is left/right symmetric and sits higher at the front than the back") {
        for style in MannequinStyle.allCases {
            for a in stride(from: Float(0), through: .pi, by: 0.2) {
                expectNear(Double(HairBuilder.hairline(phi: a, style: style)),
                           Double(HairBuilder.hairline(phi: -a, style: style)), tolerance: 1e-6, "\(style) symmetry")
            }
            expect(HairBuilder.hairline(phi: 0, style: style) > HairBuilder.hairline(phi: .pi, style: style))
        }
    }

    let scalp = MeshSmoothing.smoothed(try! GLBLoader.loadGeometry(url: headURL), iterations: 30, keepBelowY: -3.8).positions
    let base = SCNMaterial()

    test("male cut: dense strands, short (stays on the head)") {
        let hair = HairBuilder.hairNodes(scalp: scalp, style: .male, material: base)
        let strands = hair.childNodes.compactMap { $0.geometry }.map { $0.sources(for: .vertex)[0].vectorCount }.max() ?? 0
        expect(strands > 150_000, "ribbon vertices \(strands)")
        let box = boundingBox(hair)
        expect(box.min.y > -0.5, "short hair shouldn't reach below the jaw (min y \(box.min.y))")
        expect(box.max.y > 4.0, "quiff should add volume above the crown (max y \(box.max.y))")
    }

    test("female cut: ponytail falls well below the head and has a hair tie") {
        let hair = HairBuilder.hairNodes(scalp: scalp, style: .female, material: base)
        let box = boundingBox(hair)
        expect(box.min.y < -1.5, "ponytail should hang down the back (min y \(box.min.y))")
        expect(box.min.z < -2.5, "ponytail should sit behind the head (min z \(box.min.z))")
        expect(hair.childNodes.contains { $0.geometry is SCNTorus }, "hair tie")
    }

    test("head scene builds both busts and switches between them") {
        let scene = HeadScene(resources: Bundle(url: resources)!, style: .female)
        var visible = 0, hidden = 0
        scene.scene.rootNode.enumerateHierarchy { n, _ in
            if n.skinner != nil { if n.isHidden { hidden += 1 } else { visible += 1 } }
        }
        expect(visible == 1 && hidden == 1, "exactly one bust visible (visible \(visible), hidden \(hidden))")
        scene.setStyle(.male)
        scene.setPose(pitch: 0.3, yaw: -0.2, roll: 0.1)
        scene.setOffset(forwardCM: 5, dropCM: 3, immediate: true)
    }
}

@MainActor
func gridTests() {
    test("background grid is faint, line-based, and never casts shadows") {
        let grid = HeadScene.spatialGrid()
        guard let g = grid.geometry, let el = g.elements.first,
              let colors = g.sources(for: .color).first else { return expect(false, "grid geometry") }
        expect(el.primitiveType == .line)
        let alphas: [Float] = colors.data.withUnsafeBytes { b in (0..<colors.vectorCount).map { b.load(fromByteOffset: $0 * 16 + 12, as: Float.self) } }
        expect((alphas.max() ?? 1) <= 0.35, "semi-transparent (max alpha \(alphas.max() ?? -1))")
        expect(!grid.castsShadow && g.firstMaterial?.writesToDepthBuffer == false)
    }
}
