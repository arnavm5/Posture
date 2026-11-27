import Foundation
import simd

/// One 25 Hz motion sample with the head held at `g` (no movement).
private func still(_ g: SIMD3<Double>) -> HeadKinematics {
    HeadKinematics(gravity: g, accel: .zero, omega: .zero, alpha: .zero, translational: .zero,
                   rotation: matrix_identity_double3x3, dt: 0.04)
}

private func feed(_ s: inout CalibrationSession, _ g: SIMD3<Double>, seconds: Double) {
    for _ in 0..<Int(seconds * 25) { _ = s.record(still(g)) }
}

/// Nods down to 24° and back up over 2 s.
private func nod(_ s: inout CalibrationSession) {
    for i in 0...50 {
        let p: Double = 24 * sin(Double(i) / 50 * .pi)
        _ = s.record(still(gravity(pitchDegrees: p)))
    }
}

func calibrationSessionTests() {
    print("Calibration sequence")
    let g0 = SIMD3<Double>(0, 0, -1)

    test("steps, prompts and progress") {
        let with = CalibrationSession(slouchTest: true, earbud: .left, deskMode: .sitting)
        expect(with.steps == [.neutral, .lookDown, .slouch, .sitTall, .turn, .tilt])
        expect(with.progress.index == 1 && with.progress.of == 6)
        expect(with.prompt.hasPrefix("Sit up straight"))
        let without = CalibrationSession(slouchTest: false, earbud: .left, deskMode: .standing)
        expect(without.steps == [.neutral, .lookDown, .turn, .tilt])
        expect(without.prompt.hasPrefix("Stand up straight"))
    }

    test("sit up straight ends early once held, and skips the first moments") {
        var s = CalibrationSession(slouchTest: false, earbud: .left, deskMode: .sitting)
        var endedAt: Double?
        for i in 1...200 where endedAt == nil {
            if s.record(still(g0)) { endedAt = Double(i) * 0.04 }
        }
        expectNear(endedAt ?? 99, 3, tolerance: 0.1, "ended")
        expect(s.neutralSamples.count < Int((endedAt ?? 0) * 25), "the first 0.75 s weren't recorded")
    }

    test("a full run with the slouch test sets your limits and refines nothing it shouldn't") {
        var s = CalibrationSession(slouchTest: true, earbud: .left, deskMode: .sitting)
        feed(&s, g0, seconds: 4)
        expect(s.compensatorLever == .zero, "no compensation while the lever is being fitted")
        expect(s.advance() == .next(.lookDown))
        nod(&s)
        expect(s.advance() == .next(.slouch))
        expect(simd_length(s.compensatorLever) > 0.05, "slouching is measured with the provisional lever")
        feed(&s, gravity(pitchDegrees: 25), seconds: 6)
        expect(s.advance() == .next(.sitTall))
        feed(&s, g0, seconds: 4)
        expect(s.advance() == .next(.turn))
        expect(s.compensatorLever == .zero)
        feed(&s, g0, seconds: 4)
        expect(s.advance() == .next(.tilt))
        feed(&s, g0, seconds: 4)
        expect(s.advance() == .finished)
        guard case .success(let done) = s.finish(currentTiltLimit: 20, currentShiftCM: 5)
        else { return expect(false, "should calibrate") }
        expect(done.forwardTilt == 15, "0.6 × 25° slouch: \(String(describing: done.forwardTilt))")
        expect(done.shiftCM == nil, "a pure tilt doesn't set the shift limit")
        expect(done.slouchTest != nil)
        expect(done.notes.contains { $0.contains("forward tilt 20° → 15°") }, "\(done.notes)")
        expect(done.notes.contains { $0.contains("turn and tilt") }, "lever not fitted: \(done.notes)")
        expect(done.calibration.earbud == .left)
    }

    test("the slouch test fails early when you didn't look down") {
        var s = CalibrationSession(slouchTest: true, earbud: .left, deskMode: .sitting)
        feed(&s, g0, seconds: 4)
        _ = s.advance()
        feed(&s, g0, seconds: 2)                       // never looked down
        expect(s.advance() == .failed(.didNotLookDown))
        expect(s.step == .lookDown, "stays put; the app ends the run")
        var plain = CalibrationSession(slouchTest: false, earbud: .left, deskMode: .standing)
        feed(&plain, g0, seconds: 4)
        _ = plain.advance()
        feed(&plain, g0, seconds: 2)
        guard case .failure(let f) = plain.finish(currentTiltLimit: 15, currentShiftCM: 5)
        else { return expect(false, "should fail") }
        expect(f == .didNotLookDown)
        expect(f.message(deskMode: .standing).contains("look down"))
        expect(HeadCalibration.Failure.notStill.message(deskMode: .standing).contains("standing"))
    }

    test("a slouch test with a dropped signal keeps your limits") {
        var s = CalibrationSession(slouchTest: true, earbud: .left, deskMode: .sitting)
        feed(&s, g0, seconds: 4)
        _ = s.advance()
        nod(&s)
        _ = s.advance()
        feed(&s, gravity(pitchDegrees: 25), seconds: 1)     // 1 s of samples in a 6 s step
        _ = s.advance()
        feed(&s, g0, seconds: 4)
        guard case .success(let done) = s.finish(currentTiltLimit: 15, currentShiftCM: 5)
        else { return expect(false, "still calibrates") }
        expect(done.forwardTilt == nil && done.shiftCM == nil && done.slouchTest == nil)
        expect(done.notes.contains { $0.contains("signal dropped") }, "\(done.notes)")
    }
}
