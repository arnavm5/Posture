import Foundation
import SceneKit

/// Minimal glTF-binary (.glb) reader: loads the first mesh primitive (positions, normals, UVs, indices).
enum GLBLoader {
    enum LoadError: Error { case badFile, unsupported }

    static func loadGeometry(url: URL, transform: ((SIMD3<Float>) -> SIMD3<Float>)? = nil) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(data[o..<o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        guard data.count > 20, u32(0) == 0x4654_6C67 else { throw LoadError.badFile }   // "glTF"

        let jsonLen = u32(12)
        let binStart = 20 + jsonLen + 8
        guard jsonLen > 0, binStart <= data.count else { throw LoadError.badFile }   // check before slicing
        let json = try JSONSerialization.jsonObject(with: data[20..<20 + jsonLen]) as? [String: Any] ?? [:]
        let bin = data[binStart...]

        guard let accessors = json["accessors"] as? [[String: Any]],
              let views = json["bufferViews"] as? [[String: Any]],
              let mesh = (json["meshes"] as? [[String: Any]])?.first,
              let prim = (mesh["primitives"] as? [[String: Any]])?.first,
              let attrs = prim["attributes"] as? [String: Int],
              let posIdx = attrs["POSITION"], let indIdx = prim["indices"] as? Int
        else { throw LoadError.unsupported }

        func bytes(_ accessor: Int) -> (Data, count: Int, type: Int) {
            let a = accessors[accessor]
            let v = views[a["bufferView"] as? Int ?? 0]
            let off = bin.startIndex + (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            let len = v["byteLength"] as? Int ?? 0
            return (Data(bin[off..<Swift.min(off + len, bin.endIndex)]), a["count"] as? Int ?? 0, a["componentType"] as? Int ?? 0)
        }

        func floats(_ accessor: Int, comps: Int) -> Data {
            let (d, count, _) = bytes(accessor)
            return d.prefix(count * comps * 4)
        }

        var sources: [SCNGeometrySource] = []
        let (_, vcount, _) = bytes(posIdx)
        var posData = floats(posIdx, comps: 3)
        if let transform {
            var pts = posData.withUnsafeBytes { b in (0..<vcount).map { i in SIMD3<Float>(b.load(fromByteOffset: i * 12, as: Float.self), b.load(fromByteOffset: i * 12 + 4, as: Float.self), b.load(fromByteOffset: i * 12 + 8, as: Float.self)) } }
            pts = pts.map(transform)
            posData = Data(pts.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        sources.append(SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: vcount,
                                         usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                         dataOffset: 0, dataStride: 12))
        if let n = attrs["NORMAL"] {
            sources.append(SCNGeometrySource(data: floats(n, comps: 3), semantic: .normal, vectorCount: vcount,
                                             usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 12))
        }
        if let t = attrs["TEXCOORD_0"] {
            sources.append(SCNGeometrySource(data: floats(t, comps: 2), semantic: .texcoord, vectorCount: vcount,
                                             usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 8))
        }

        let (idata, icount, itype) = bytes(indIdx)
        let size = itype == 5125 ? 4 : itype == 5123 ? 2 : 0
        guard size > 0 else { throw LoadError.unsupported }
        let element = SCNGeometryElement(data: idata.prefix(icount * size), primitiveType: .triangles,
                                         primitiveCount: icount / 3, bytesPerIndex: size)
        return SCNGeometry(sources: sources, elements: [element])
    }
}

extension SCNGeometry {
    /// Vertex positions of the first vertex source.
    var positions: [SIMD3<Float>] {
        guard let src = sources(for: .vertex).first else { return [] }
        return src.data.withUnsafeBytes { b in
            (0..<src.vectorCount).map { i in
                let o = src.dataOffset + i * src.dataStride
                return SIMD3(b.load(fromByteOffset: o, as: Float.self),
                             b.load(fromByteOffset: o + 4, as: Float.self),
                             b.load(fromByteOffset: o + 8, as: Float.self))
            }
        }
    }
}

enum MeshSmoothing {
    /// Taubin-smooths a triangle mesh (no shrinkage) to turn a detailed scan into a soft, stylised form.
    /// Vertices split at UV seams are welded for smoothing so no cracks open. Returns new geometry with fresh normals.
    static func smoothed(_ geometry: SCNGeometry, iterations: Int, keepBelowY: Float,
                         lambda: Float = 0.5, mu: Float = -0.53,
                         weight: ((SIMD3<Float>) -> Float)? = nil) -> SCNGeometry {
        let pts = geometry.positions
        guard let element = geometry.elements.first, !pts.isEmpty else { return geometry }

        // Weld coincident vertices.
        var weld = [Int](repeating: 0, count: pts.count)
        var keyToId: [SIMD3<Int32>: Int] = [:]
        var uniq: [SIMD3<Float>] = []
        for (i, p) in pts.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 2000).rounded()), Int32((p.y * 2000).rounded()), Int32((p.z * 2000).rounded()))
            if let id = keyToId[k] { weld[i] = id } else { keyToId[k] = uniq.count; weld[i] = uniq.count; uniq.append(p) }
        }

        let tris: [Int] = element.data.withUnsafeBytes { b in
            (0..<element.primitiveCount * 3).map { i in
                element.bytesPerIndex == 2 ? Int(b.load(fromByteOffset: i * 2, as: UInt16.self))
                                           : Int(b.load(fromByteOffset: i * 4, as: UInt32.self))
            }
        }
        var nbrs = [Set<Int>](repeating: [], count: uniq.count)
        for t in stride(from: 0, to: tris.count, by: 3) {
            let a = weld[tris[t]], b = weld[tris[t + 1]], c = weld[tris[t + 2]]
            nbrs[a].formUnion([b, c]); nbrs[b].formUnion([a, c]); nbrs[c].formUnion([a, b])
        }
        let adj = nbrs.map(Array.init)

        var p = uniq
        // Optional per-vertex strength (e.g. smooth only around the eyes), from the original positions.
        let strength = uniq.map { weight?($0) ?? 1 }
        func step(_ f: Float) {
            var next = p
            for i in 0..<p.count where !adj[i].isEmpty && p[i].y > keepBelowY && strength[i] > 0.001 {
                let avg = adj[i].reduce(SIMD3<Float>.zero) { $0 + p[$1] } / Float(adj[i].count)
                next[i] = p[i] + f * strength[i] * (avg - p[i])
            }
            p = next
        }
        for _ in 0..<iterations { step(lambda); step(mu) }

        // Fresh smooth normals on the welded mesh.
        var n = [SIMD3<Float>](repeating: .zero, count: p.count)
        for t in stride(from: 0, to: tris.count, by: 3) {
            let a = weld[tris[t]], b = weld[tris[t + 1]], c = weld[tris[t + 2]]
            let fn = simd_cross(p[b] - p[a], p[c] - p[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        let outP = weld.map { p[$0] }
        let outN = weld.map { simd_length(n[$0]) > 0 ? simd_normalize(n[$0]) : SIMD3<Float>(0, 1, 0) }

        var sources = [SCNGeometrySource(vertices: outP.map { SCNVector3($0) }),
                       SCNGeometrySource(normals: outN.map { SCNVector3($0) })]
        sources += geometry.sources(for: .texcoord)
        return SCNGeometry(sources: sources, elements: [element])
    }
}
