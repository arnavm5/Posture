import AppKit
import SceneKit
import simd

typealias PlatformColor = NSColor

extension NSColor {
    /// sRGB components as floats.
    var rgba: SIMD4<Float> {
        let c = usingColorSpace(.sRGB) ?? self
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(red: r, green: g, blue: b, alpha: a)
    }
}

/// SceneKit translation matrix.
func scnTranslation(_ v: SIMD3<Float>) -> SCNMatrix4 {
    SCNMatrix4(simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(v.x, v.y, v.z, 1))))
}
