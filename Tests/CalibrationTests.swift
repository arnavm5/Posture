import Foundation
import simd

func calibrationTests() {
    print("Calibration & posture rules")
    let g0 = SIMD3<Double>(0, 0, -1)
    let neutral = Array(repeating: g0, count: 60)
    let lookDown = (0...40).map { gravity(pitchDegrees: Double($0) * 0.6) }

    test("solves the head frame from sitting tall + looking down") {
        guard case .success(let cal) = HeadCalibration.solve(neutral: neutral, lookDown: lookDown, leverFit: LeverArmFit(), earbud: .left)
        else { return expect(false, "should succeed") }
        expect(simd_length(cal.forward - SIMD3(0, 1, 0)) < 1e-6, "forward \(cal.forward)")
        expect(simd_length(cal.up - SIMD3(0, 0, 1)) < 1e-6, "up \(cal.up)")
        expect(simd_length(cal.left - SIMD3(-1, 0, 0)) < 1e-6, "left \(cal.left)")
        expect(!cal.leverFitted && abs(simd_length(cal.leverArm) - 0.09) < 1e-9, "default lever when no rotation data")
        expect(cal.earbud == .left)
    }

    test("fails clearly when you don't look down") {
        let r = HeadCalibration.solve(neutral: neutral, lookDown: neutral, leverFit: LeverArmFit(), earbud: .unknown)
        guard case .failure(let f) = r else { return expect(false, "should fail") }
        expect(f == .didNotLookDown)
        guard case .failure(.noSignal) = HeadCalibration.solve(neutral: [], lookDown: lookDown, leverFit: LeverArmFit(), earbud: .unknown)
        else { return expect(false, "no samples should fail with noSignal") }
    }

    test("each earbud keeps its own calibration") {
        let left = HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0), leverArm: SIMD3(0.05, 0, 0.07), leverFitted: true, earbud: .left)
        let right = HeadCalibration(neutralGravity: SIMD3(0.1, 0, -1), forward: SIMD3(0, 1, 0), leverArm: SIMD3(-0.05, 0, 0.07), leverFitted: true, earbud: .right)
        left.save(); right.save()
        expect(HeadCalibration.load(for: .left) == left)
        expect(HeadCalibration.load(for: .right) == right)
        for e in [Earbud.left, .right] { UserDefaults.standard.removeObject(forKey: "calibration.\(e.rawValue)") }
    }

    test("posture rules: forward tilt, side tilt and head shift each count") {
        let rules = PostureRules(maxForwardTilt: 15, maxSideTilt: 12, maxShiftCM: 5)
        expect(rules.reasons(for: PostureReading()).isEmpty, "neutral is fine")
        expect(rules.reasons(for: PostureReading(pitch: 10, roll: 8)).isEmpty, "small tilts are fine")
        expect(rules.reasons(for: PostureReading(pitch: -30)).isEmpty, "looking up isn't slouching")
        expect(rules.reasons(for: PostureReading(pitch: 20)).first?.contains("forward") == true)
        expect(rules.reasons(for: PostureReading(roll: -15)).first?.contains("right") == true)
        expect(rules.reasons(for: PostureReading(roll: 15)).first?.contains("left") == true)
        expect(rules.reasons(for: PostureReading(forwardCM: 6)).count == 1)
        expect(rules.reasons(for: PostureReading(dropCM: 6)).count == 1)
    }
}
