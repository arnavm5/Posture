import Foundation
import SceneKit
import simd

/// Mannequin looks: a male bust and a (reshaped) female bust with different hairstyles.
enum MannequinStyle: String, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var label: String { self == .male ? "Male" : "Female" }
}

/// Strand-based hair.
///
/// Hair is grown as ~1,000 "guide" strands from the scalp, each shaped by the hairstyle and kept
/// outside the head. Every guide spawns a clump of child strands that bunch together toward the tips,
/// which is what makes real hair read as hair. Strands are rendered as thin, tapered ribbons with
/// root-to-tip colour variation over a dark scalp layer.
///
/// Styles: **male**, a textured quiff with short faded sides;
///         **female**, a sleek high ponytail with a wavy tail and face-framing tendrils.
enum HairBuilder {
    /// Rough centre of the skull in model space (used for spherical coordinates).
    static let center = SIMD3<Float>(0, 1.4, 0.0)

    // MARK: Female bust

    /// Reshapes the (male) head scan into a female bust: softer brow, smaller nose, slimmer jaw,
    /// neck and shoulders, slightly fuller lips.
    static func femaleMorph(_ p0: SIMD3<Float>) -> SIMD3<Float> {
        var p = p0
        let face = smoothstep(1.2, 2.0, p.z)                                          // front of the face only
        p.z -= 0.10 * gauss(p.y - 1.95, 0.22) * gauss(p.x, 0.9) * face                  // brow ridge
        p.z -= 0.13 * gauss(p.y - 1.05, 0.35) * gauss(p.x, 0.35) * face                 // nose
        p.x *= 1 - 0.06 * gauss(p.y - 1.05, 0.3) * gauss(p.x, 0.3) * face               // narrower nose
        p.z += 0.05 * gauss(p.y - 0.30, 0.14) * gauss(p.x, 0.35) * face                 // fuller lips
        let jaw = smoothstep(1.4, 0.4, p.y) * (1 - smoothstep(-0.6, -1.0, p.y))
        p.x *= 1 - 0.13 * jaw                                                         // slimmer jaw & chin
        p.z = (p.z - 0.6) * (1 - 0.05 * jaw) + 0.6
        // Slimmer neck: pull toward the neck axis.
        let neck = smoothstep(-0.4, -0.9, p.y) * (1 - smoothstep(-1.6, -2.2, p.y))
        let axis = SIMD2<Float>(0, -0.35)
        var r = SIMD2(p.x, p.z) - axis
        if simd_length(r) < 1.9 { r *= 1 - 0.12 * neck }
        p.x = axis.x + r.x; p.z = axis.y + r.y
        p.x *= 1 - 0.10 * smoothstep(-1.4, -2.4, p.y)                                // narrower shoulders
        return p
    }

    // MARK: Public

    static func hairNodes(scalp points: [SIMD3<Float>], style: MannequinStyle, material _: SCNMaterial) -> SCNNode {
        let map = RadialMap(points: points, center: center)
        var rng = RNG(seed: style == .male ? 11 : 29)
        let look = Look(style)
        let root = SCNNode()

        let cap = SCNNode(geometry: capGeometry(map: map, style: style))
        cap.geometry?.firstMaterial = matte(look.root)
        root.addChildNode(cap)

        var guides: [Guide] = []
        var gather: (point: SIMD3<Float>, dir: SIMD3<Float>)?
        switch style {
        case .male:
            guides = maleGuides(map: map, rng: &rng)
        case .female:
            let g = ponytailGather(map: map)
            gather = g
            guides = ponytailGuides(map: map, gather: g, rng: &rng) + tendrilGuides(map: map, rng: &rng)
        }
        let strands = grow(children: guides, map: map, rng: &rng)
        let hair = SCNNode(geometry: ribbons(strands, look: look, rng: &rng))
        hair.geometry?.firstMaterial = strandMaterial()
        root.addChildNode(hair)

        if let gather {
            let tie = SCNNode(geometry: SCNTorus(ringRadius: 0.16, pipeRadius: 0.055))
            tie.geometry?.firstMaterial = matte(PlatformColor(white: 0.08, alpha: 1), roughness: 0.4)
            tie.simdPosition = gather.point + gather.dir * 0.12
            tie.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: gather.dir)
            root.addChildNode(tie)
        }
        return root
    }

    // MARK: Look

    private struct Look {
        let root: PlatformColor, tip: PlatformColor
        init(_ style: MannequinStyle) {
            switch style {
            case .male:   // soft black
                root = PlatformColor.rgb(0.035, 0.03, 0.028)
                tip = PlatformColor.rgb(0.16, 0.13, 0.11)
            case .female: // espresso roots melting into caramel ends
                root = PlatformColor.rgb(0.07, 0.045, 0.03)
                tip = PlatformColor.rgb(0.55, 0.36, 0.20)
            }
        }
    }

    private static func matte(_ c: PlatformColor, roughness: CGFloat = 0.9) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = roughness
        m.metalness.contents = 0
        return m
    }

    private static func strandMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = PlatformColor.white            // tinted by per-vertex colour
        m.roughness.contents = 0.68
        m.metalness.contents = 0
        m.isDoubleSided = true
        return m
    }

    // MARK: Strand data

    private struct Guide {
        var points: [SIMD3<Float>]
        var width: Float
        var clump: Float          // 0 = children stay parallel, 1 = children meet the guide at the tip
        var spread: Float         // child root scatter radius
        var children: Int
        var frizz: Float
        var collide = true        // keep the strand outside the head
    }

    private struct Strand {
        var points: [SIMD3<Float>]
        var width: Float
        var tint: Float
    }

    // MARK: Male: textured quiff, short faded sides

    private static func maleGuides(map: RadialMap, rng: inout RNG) -> [Guide] {
        var guides: [Guide] = []
        for (phi, el) in scalpSamples(count: 1300, style: .male, rng: &rng) {
            let eh = hairline(phi: phi, style: .male)
            let s = (el - eh) / (.pi / 2 - eh)                                    // 0 hairline … 1 crown
            let front = gauss(phi, 0.85)
            let top = smoothstep(0.32 - 0.34 * front, 0.48 - 0.36 * front, s)     // long hair on top & front
            let n = direction(phi: phi, el: el)
            let root = center + n * map.radius(phi: phi, el: el)

            let length = mix(0.07 + 0.22 * smoothstep(0.0, 0.4, s), 0.85 + 0.55 * front + 0.15 * Float(rng.next()), top)
            let segments = top > 0.5 ? 12 : 5
            var p = root, pts = [root]
            var d = simd_normalize(n * (0.12 + 0.88 * top)
                                   + SIMD3(0, 1, 0) * 0.45 * front * top
                                   + tangential(SIMD3(0, -1, -0.35), n) * (1 - top))
            for k in 1...segments {
                let here = simd_normalize(p - center)
                let back = tangential(SIMD3(0.18, 0.15, -1), here)               // sweep back and slightly to one side
                let down = tangential(SIMD3(0, -1, -0.3), here)
                d = simd_normalize(d + (back * 0.42 + SIMD3(0, -0.04, 0)) * top + down * 0.6 * (1 - top))
                p += d * (length / Float(segments))
                p = pushOut(p, map: map, lift: 0.02 + 0.24 * top * Float(k) / Float(segments) * (0.6 + 0.4 * front))
                pts.append(p)
            }
            guides.append(Guide(points: pts, width: top > 0.5 ? 0.036 : 0.022, clump: top > 0.5 ? 0.7 : 0.35,
                                spread: top > 0.5 ? 0.08 : 0.05, children: top > 0.5 ? 14 : 8,
                                frizz: top > 0.5 ? 0.006 : 0.003))
        }
        return guides
    }

    // MARK: Female: high ponytail

    private static func ponytailGather(map: RadialMap) -> (point: SIMD3<Float>, dir: SIMD3<Float>) {
        let phi: Float = .pi, el: Float = 38 * .pi / 180
        let n = direction(phi: phi, el: el)
        let p = center + n * (map.radius(phi: phi, el: el) + 0.12)
        return (p, simd_normalize(n + SIMD3(0, 0.4, 0)))
    }

    private static func ponytailGuides(map: RadialMap, gather g: (point: SIMD3<Float>, dir: SIMD3<Float>),
                                       rng: inout RNG) -> [Guide] {
        // Centre line of the tail: lifts out of the tie, arcs back, then falls in a loose S down the back.
        let spine: [SIMD3<Float>] = [g.point, g.point + SIMD3(0, 0.55, -0.55), SIMD3(0, 2.7, -3.0),
                                     SIMD3(0.15, 1.0, -3.15), SIMD3(-0.1, -0.6, -3.05), SIMD3(0.12, -2.2, -3.0),
                                     SIMD3(0.05, -3.2, -2.9)]
        var guides: [Guide] = []
        for (phi, el) in scalpSamples(count: 1100, style: .female, rng: &rng) {
            let n = direction(phi: phi, el: el)
            // Scalp part: combed sleekly over the head into the tie.
            let tieOffset = disk(around: g.dir, radius: 0.11, rng: &rng)
            let target = g.point + tieOffset
            let tdir = simd_normalize(target - center)
            let layer = 0.02 + 0.05 * Float(rng.next())                       // overlapping layers, no gaps
            var pts: [SIMD3<Float>] = []
            let scalpSteps = 12
            for k in 0...scalpSteps {
                let t = Float(k) / Float(scalpSteps)
                let d = simd_normalize(mix(n, tdir, t) + 0.0001)
                let sp = sphericalAngles(d)
                let onScalp = center + d * (map.radius(phi: sp.phi, el: sp.el) + layer + 0.03 * t)
                pts.append(mix(onScalp, target, smoothstep(0.75, 1.0, t)))
            }
            // Tail: follows the spine with its own offset, fanning out and tapering, with soft waves.
            let lengthEnd = 0.72 + 0.28 * Float(rng.next())
            let side = disk(around: SIMD3(0, 1, 0), radius: 1, rng: &rng)
            let phase = Float(rng.next()) * 2 * .pi
            let tailSteps = 26
            for k in 1...tailSteps {
                let t = Float(k) / Float(tailSteps) * lengthEnd
                let c = catmullRom(spine, t)
                let fan = 0.10 + 0.42 * sin(min(t * 1.25, 1) * .pi) * (1 - 0.4 * t)
                let wave = SIMD3<Float>(sin(t * 9 + phase), 0, cos(t * 7 + phase)) * 0.07 * t
                var p = c + side * fan * smoothstep(0, 0.18, t) + wave
                p.z = min(p.z, backSurfaceZ(y: p.y) - 0.12)                       // stay behind the head/back
                pts.append(p)
            }
            guides.append(Guide(points: pts, width: 0.034, clump: 0.55, spread: 0.06, children: 12,
                                frizz: 0.01, collide: false))
        }
        return guides
    }

    /// Two loose, wavy pieces framing the face.
    private static func tendrilGuides(map: RadialMap, rng: inout RNG) -> [Guide] {
        var guides: [Guide] = []
        for sideSign: Float in [-1, 1] {
            for _ in 0..<14 {
                let phi = sideSign * (1.08 + 0.12 * Float(rng.next()))
                let el = (14 + 8 * Float(rng.next())) * .pi / 180
                let n = direction(phi: phi, el: el)
                let root = center + n * map.radius(phi: phi, el: el)
                let out = simd_normalize(SIMD3(n.x, 0, n.z))
                let phase = Float(rng.next()) * 2 * .pi
                var pts = [root]
                let steps = 16
                for k in 1...steps {
                    let t = Float(k) / Float(steps)
                    var p = root + SIMD3(0, -1.7 * t, 0.25 * t) + out * (0.14 + 0.06 * sin(t * 10 + phase))
                    p = pushOut(p, map: map, lift: 0.05)
                    pts.append(p)
                }
                guides.append(Guide(points: pts, width: 0.018, clump: 0.7, spread: 0.04, children: 8, frizz: 0.008))
            }
        }
        return guides
    }

    // MARK: Children (clumping)

    private static func grow(children guides: [Guide], map: RadialMap, rng: inout RNG) -> [Strand] {
        var strands: [Strand] = []
        for g in guides {
            let n = g.points.count
            let rootNormal = simd_normalize(g.points[0] - center)
            for c in 0...g.children {
                let offset = c == 0 ? .zero : disk(around: rootNormal, radius: g.spread, rng: &rng)
                var pts: [SIMD3<Float>] = []
                pts.reserveCapacity(n)
                for (i, gp) in g.points.enumerated() {
                    let t = Float(i) / Float(max(1, n - 1))
                    let jitter = SIMD3(Float(rng.next()) - 0.5, Float(rng.next()) - 0.5, Float(rng.next()) - 0.5) * g.frizz * t
                    var p = gp + offset * (1 - g.clump * pow(t, 0.8)) + jitter
                    if g.collide { p = pushOut(p, map: map, lift: 0.012) }
                    pts.append(p)
                }
                let tipCut = Int(Float(n) * Float(rng.next()) * 0.15)              // uneven ends
                strands.append(Strand(points: Array(pts.prefix(max(2, n - tipCut))), width: g.width * (0.8 + 0.4 * Float(rng.next())),
                                      tint: 0.85 + 0.3 * Float(rng.next())))
            }
        }
        return strands
    }

    // MARK: Ribbon mesh

    private static func ribbons(_ strands: [Strand], look: Look, rng: inout RNG) -> SCNGeometry {
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], col: [SIMD4<Float>] = [], idx: [UInt32] = []
        let total = strands.reduce(0) { $0 + $1.points.count }
        pos.reserveCapacity(total * 2); nor.reserveCapacity(total * 2); col.reserveCapacity(total * 2)
        idx.reserveCapacity(total * 6)
        let rootC = look.root.rgba, tipC = look.tip.rgba

        for s in strands {
            let n = s.points.count
            let base = UInt32(pos.count)
            for i in 0..<n {
                let p = s.points[i]
                let tangent = simd_normalize(i < n - 1 ? s.points[i + 1] - p : p - s.points[i - 1])
                let out = simd_normalize(p - center)
                var side = simd_cross(tangent, out)
                if simd_length(side) < 1e-3 { side = simd_cross(tangent, SIMD3(0, 1, 0)) }
                side = simd_normalize(side)
                var normal = simd_normalize(simd_cross(side, tangent))
                if simd_dot(normal, out) < 0 { normal = -normal }
                let t = Float(i) / Float(n - 1)
                let w = s.width * (1 - 0.85 * t) * 0.5
                pos.append(p - side * w); pos.append(p + side * w)
                nor.append(normal); nor.append(normal)
                var c = mix(rootC, tipC, pow(t, 1.2)) * s.tint
                c.w = 1
                col.append(c); col.append(c)
            }
            for i in 0..<UInt32(n - 1) {
                let a = base + 2 * i
                idx += [a, a + 1, a + 3, a, a + 3, a + 2]
            }
        }
        let colorData = col.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: col.count, usesFloatComponents: true,
                                            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos.map { SCNVector3($0) }),
                                     SCNGeometrySource(normals: nor.map { SCNVector3($0) }),
                                     colorSource],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    // MARK: Scalp

    /// Area-uniform samples of (phi, elevation) inside the hairline.
    private static func scalpSamples(count: Int, style: MannequinStyle, rng: inout RNG) -> [(Float, Float)] {
        var out: [(Float, Float)] = []
        let minSin = sin(-40 * Float.pi / 180)
        while out.count < count {
            let phi = Float(rng.next()) * 2 * .pi - .pi
            let el = asin(minSin + (1 - minSin) * Float(rng.next()))
            if el > hairline(phi: phi, style: style) + 0.02 { out.append((phi, el)) }
        }
        // Extra-dense roots along the hairline so the edge reads as a soft, full hairline.
        for _ in 0..<(count / 3) {
            let phi = Float(rng.next()) * 2 * .pi - .pi
            out.append((phi, hairline(phi: phi, style: style) + 0.015 + 0.13 * Float(rng.next())))
        }
        return out
    }

    /// Thin dark layer on the scalp so no skin shows between strands.
    private static func capGeometry(map: RadialMap, style: MannequinStyle) -> SCNGeometry {
        let cols = 160, rows = 40
        return Grid.geometry(rows: rows + 1, cols: cols) { i, j in
            let phi = -Float.pi + 2 * .pi * Float(j) / Float(cols)
            let eh = hairline(phi: phi, style: style)
            let s = 1 - Float(min(i, rows)) / Float(rows)
            let el = eh + (.pi / 2 - eh) * s
            let r = map.radius(phi: phi, el: el) + (i > rows ? -0.04 : 0.008)
            return center + direction(phi: phi, el: el) * r
        }
    }

    /// Hairline elevation (radians) around the head (0 = front).
    static func hairline(phi: Float, style: MannequinStyle) -> Float {
        let male: [(Float, Float)] = [(0, 33), (25, 32), (45, 27), (60, 10), (70, -4), (80, -2), (90, 18),
                                      (115, 20), (135, 2), (160, -24), (180, -30)]
        let female: [(Float, Float)] = [(0, 30), (25, 28), (45, 22), (60, 6), (72, -4), (84, 0), (92, 14),
                                        (115, 16), (135, -4), (160, -24), (180, -28)]
        let table = style == .male ? male : female
        let a = abs(phi) * 180 / .pi
        for k in 1..<table.count where a <= table[k].0 {
            let (a0, e0) = table[k - 1], (a1, e1) = table[k]
            return (e0 + (e1 - e0) * smoothstep(a0, a1, a)) * .pi / 180
        }
        return table.last!.1 * .pi / 180
    }

    // MARK: Geometry helpers

    /// Keeps a point at least `lift` above the head surface.
    private static func pushOut(_ p: SIMD3<Float>, map: RadialMap, lift: Float) -> SIMD3<Float> {
        let d = p - center
        let len = simd_length(d)
        guard len > 1e-4 else { return p }
        let dir = d / len
        let a = sphericalAngles(dir)
        guard a.el > -0.45 else { return p }                         // below the skull: not the head anymore
        let minR = map.radius(phi: a.phi, el: a.el) + lift
        return len < minR ? center + dir * minR : p
    }

    /// Approximate back surface of head, neck and upper back (z as a function of height).
    private static func backSurfaceZ(y: Float) -> Float {
        let table: [(Float, Float)] = [(3.5, -1.6), (2.0, -2.0), (0.8, -1.9), (-0.3, -1.4), (-1.1, -1.35),
                                       (-1.8, -2.1), (-2.6, -2.5), (-4.0, -2.6)]
        if y >= table[0].0 { return table[0].1 }
        for k in 1..<table.count where y >= table[k].0 {
            let (y0, z0) = table[k - 1], (y1, z1) = table[k]
            return z0 + (z1 - z0) * (y0 - y) / (y0 - y1)
        }
        return table.last!.1
    }

    private static func tangential(_ v: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let t = v - simd_dot(v, n) * n
        return simd_length(t) > 1e-5 ? simd_normalize(t) : .zero
    }

    private static func disk(around n: SIMD3<Float>, radius: Float, rng: inout RNG) -> SIMD3<Float> {
        let a = simd_normalize(simd_cross(n, abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        let b = simd_cross(n, a)
        let r = radius * Float(rng.next()).squareRoot(), th = Float(rng.next()) * 2 * .pi
        return a * (r * cos(th)) + b * (r * sin(th))
    }

    private static func catmullRom(_ pts: [SIMD3<Float>], _ t: Float) -> SIMD3<Float> {
        let f = min(max(t, 0), 0.9999) * Float(pts.count - 1)
        let i = Int(f), u = f - Float(i)
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[min(i + 1, pts.count - 1)], p3 = pts[min(i + 2, pts.count - 1)]
        let u2 = u * u, u3 = u2 * u
        let a = 2 * p1, b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, d = -p0 + 3 * p1 - 3 * p2 + p3
        return 0.5 * (a + b * u + c * u2 + d * u3)
    }

    static func sphericalAngles(_ d: SIMD3<Float>) -> (phi: Float, el: Float) {
        (atan2(d.x, d.z), asin(min(1, max(-1, d.y))))
    }

    static func direction(phi: Float, el: Float) -> SIMD3<Float> {
        SIMD3(cos(el) * sin(phi), sin(el), cos(el) * cos(phi))
    }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private static func gauss(_ d: Float, _ s: Float) -> Float { exp(-(d * d) / (s * s)) }
    private static func mix<T: SIMD>(_ a: T, _ b: T, _ t: T.Scalar) -> T where T.Scalar: FloatingPoint { a + (b - a) * t }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    struct RNG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}

/// Head-scan radius from `center`, as a smooth function of direction (ears excluded).
struct RadialMap {
    private let nPhi = 72, nEl = 36
    private var r: [Float]
    let center: SIMD3<Float>

    init(points: [SIMD3<Float>], center: SIMD3<Float>) {
        self.center = center
        r = Array(repeating: 0, count: nPhi * nEl)
        for p in points {
            if abs(p.x) > 1.55 && p.y < 2.15 && p.y > 0.3 && p.z > -1.0 && p.z < 0.7 { continue }   // ears
            let d = p - center
            let len = simd_length(d)
            guard len > 0.5 else { continue }
            let phi = atan2(d.x, d.z), el = asin(d.y / len)
            let k = index(phiBin(phi), elBin(el))
            r[k] = max(r[k], len)
        }
        for _ in 0..<40 where r.contains(0) {
            var next = r
            for e in 0..<nEl { for p in 0..<nPhi where r[index(p, e)] == 0 {
                let ns = neighbours(p, e).map { r[$0] }.filter { $0 > 0 }
                if !ns.isEmpty { next[index(p, e)] = ns.reduce(0, +) / Float(ns.count) }
            } }
            r = next
        }
        let unblurred = r
        for _ in 0..<2 {
            var next = r
            for e in 0..<nEl { for p in 0..<nPhi {
                let ns = neighbours(p, e).map { r[$0] } + [r[index(p, e)] * 2]
                next[index(p, e)] = ns.reduce(0, +) / Float(ns.count + 1)
            } }
            r = next
        }
        // Never sit below the real surface (blurring lowers bumps like the forehead), plus a small margin.
        r = zip(r, unblurred).map { max($0, $1) + 0.03 }
    }

    func radius(phi: Float, el: Float) -> Float {
        let fp = (phi + .pi) / (2 * .pi) * Float(nPhi) - 0.5
        let fe = min(Float(nEl) - 1, max(0, (el + .pi / 2) / .pi * Float(nEl) - 0.5))
        let p0 = Int(floor(fp)), e0 = Int(floor(fe))
        let tp = fp - Float(p0), te = fe - Float(e0)
        func at(_ p: Int, _ e: Int) -> Float { r[index((p % nPhi + nPhi) % nPhi, min(nEl - 1, max(0, e)))] }
        let a = at(p0, e0) * (1 - tp) + at(p0 + 1, e0) * tp
        let b = at(p0, e0 + 1) * (1 - tp) + at(p0 + 1, e0 + 1) * tp
        return a * (1 - te) + b * te
    }

    private func index(_ p: Int, _ e: Int) -> Int { e * nPhi + p }
    private func phiBin(_ phi: Float) -> Int { min(nPhi - 1, Int((phi + .pi) / (2 * .pi) * Float(nPhi))) }
    private func elBin(_ el: Float) -> Int { min(nEl - 1, max(0, Int((el + .pi / 2) / .pi * Float(nEl)))) }
    private func neighbours(_ p: Int, _ e: Int) -> [Int] {
        [(p + 1) % nPhi, (p + nPhi - 1) % nPhi].map { index($0, e) }
            + [e - 1, e + 1].filter { (0..<nEl).contains($0) }.map { index(p, $0) }
    }
}

/// Smooth-shaded mesh from a (rows+1) × cols grid that wraps horizontally.
enum Grid {
    static func geometry(rows: Int, cols: Int, point: (Int, Int) -> SIMD3<Float>) -> SCNGeometry {
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity((rows + 1) * cols)
        for i in 0...rows { for j in 0..<cols { verts.append(point(i, j)) } }
        func id(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * cols + j % cols) }
        var idx: [UInt32] = []
        idx.reserveCapacity(rows * cols * 6)
        for i in 0..<rows {
            for j in 0..<cols {
                let a = id(i, j), b = id(i + 1, j), c = id(i + 1, j + 1), d = id(i, j + 1)
                idx += [a, b, c, a, c, d]
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: verts.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let n = simd_cross(verts[b] - verts[a], verts[c] - verts[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        normals = normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts.map { SCNVector3($0) }),
                                     SCNGeometrySource(normals: normals.map { SCNVector3($0) })],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }
}
