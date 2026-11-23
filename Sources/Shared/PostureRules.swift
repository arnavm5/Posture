import Foundation

/// What counts as slouching, as a pure function so it can be tested.
/// Forward and side tilt have separate limits (from the calibrated head frame).
struct PostureRules {
    var maxForwardTilt: Double
    var maxSideTilt: Double
    var maxShiftCM: Double

    func reasons(for r: PostureReading) -> [String] {
        var out: [String] = []
        if r.pitch > maxForwardTilt { out.append("head tipped forward \(Int(r.pitch))°") }
        if abs(r.roll) > maxSideTilt { out.append("head tilted \(r.roll > 0 ? "left" : "right") \(Int(abs(r.roll)))°") }
        if r.forwardCM > maxShiftCM { out.append(String(format: "head %.0f cm forward", r.forwardCM)) }
        if r.dropCM > maxShiftCM { out.append(String(format: "head %.0f cm lower", r.dropCM)) }
        return out
    }
}
