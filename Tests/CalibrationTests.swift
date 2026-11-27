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

func calibrationAccuracyTests() {
    print("Calibration accuracy & slouch test")
    let g0 = SIMD3<Double>(0, 0, -1)
    let cal = HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0), leverArm: SIMD3(0, 0, 0.09), leverFitted: false)
    func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { CalibrationMath.angle(a, b) * 180 / .pi }
    let nod = (0...40).map { gravity(pitchDegrees: Double($0) * 0.6) }

    test("neutral uses the steadiest stretch, not the settling at the start") {
        // 1 s of still settling into the pose (8° forward → upright), then holding upright.
        let settling = (0..<25).map { gravity(pitchDegrees: 8 - Double($0) * 0.3) }
        let holding = (0..<50).map { i in gravity(pitchDegrees: 0.1 * sin(Double(i)), rollDegrees: 0.1 * cos(Double(i))) }
        guard case .success(let c) = HeadCalibration.solve(neutral: settling + holding, lookDown: nod,
                                                             leverFit: LeverArmFit(), earbud: .left)
        else { return expect(false, "should succeed") }
        expect(degrees(c.neutralGravity, g0) < 0.2, "neutral \(degrees(c.neutralGravity, g0))° off")
        expect((c.quality?.neutralSpreadDegrees ?? 99) < 0.2, "spread \(c.quality?.neutralSpreadDegrees ?? -1)")
        // The old plain average of every sample would have been ~1° off.
        var sum = SIMD3<Double>.zero
        for g in settling + holding { sum += g }
        expect(degrees(sum, g0) > 0.8, "the plain average really is worse")
    }

    test("fails if you never hold still while sitting up straight") {
        let wobbling = (0..<80).map { i in gravity(pitchDegrees: i % 2 == 0 ? 6 : -6) }
        guard case .failure(.notStill) = HeadCalibration.solve(neutral: wobbling, lookDown: nod, leverFit: LeverArmFit(), earbud: .left)
        else { return expect(false, "should fail with notStill") }
    }

    test("forward axis fits the whole nod, so one twisted sample doesn't skew it") {
        var twisted = nod
        twisted[40] = gravity(pitchDegrees: 26, rollDegrees: 14)   // lowest point, with a sideways twist
        guard case .success(let c) = HeadCalibration.solve(neutral: Array(repeating: g0, count: 60), lookDown: twisted,
                                                             leverFit: LeverArmFit(), earbud: .left)
        else { return expect(false, "should succeed") }
        let error = degrees(c.forward, SIMD3(0, 1, 0))
        expect(error < 3, "forward \(error)° off (the lowest point alone is ~28° off)")
        expect(abs(simd_dot(c.forward, c.up)) < 1e-9, "forward stays perpendicular to up")
        expect((c.quality?.nodStraightness ?? 0) > 0.9, "mostly a clean nod")
        // A nod with sideways turning in it is flagged as less straight.
        let sloppy = (0...40).map { gravity(pitchDegrees: Double($0) * 0.6, rollDegrees: 8 * sin(Double($0) * 0.5)) }
        let s = CalibrationMath.nod(neutral: g0, samples: sloppy)
        expect(s != nil && s!.straightness < (c.quality?.nodStraightness ?? 0), "sloppy nod scores lower")
    }

    test("older saved calibrations (no quality) still load") {
        let key = HeadCalibration.key(.right)
        var old = cal
        old.earbud = .right
        old.quality = nil
        old.save()
        expect(HeadCalibration.load(for: .right) == old)
        UserDefaults.standard.removeObject(forKey: key)
    }

    func samples(pitch: Double, forwardCM: Double, dropCM: Double = 0, seconds: Double = 4, settle: Double = 1.5) -> [SlouchTest.Sample] {
        let n = Int(seconds * 25)
        return (0..<n).map { i in
            let t = Double(i) / 25
            let k = min(1, t / settle)                          // move into the pose, then hold it
            let wobble = 0.15 * sin(Double(i) * 0.7)
            return SlouchTest.Sample(gravity: gravity(pitchDegrees: pitch * k + wobble), forwardCM: forwardCM * k,
                                     dropCM: dropCM * k, time: t)
        }
    }

    test("slouch hold uses the held part at the end of the step") {
        guard let h = SlouchTest.hold(samples(pitch: 25, forwardCM: 7, seconds: 6), lastSeconds: 3, window: 1.5)
        else { return expect(false, "should find a hold") }
        expectNear(SlouchTest.pitch(h.gravity, cal), 25, tolerance: 0.3, "held pitch")
        expectNear(h.forwardCM, 7, tolerance: 0.05, "held forward")
        let moving = (0..<100).map { i in
            SlouchTest.Sample(gravity: gravity(pitchDegrees: 20 * sin(Double(i) * 0.4)), forwardCM: 0, dropCM: 0, time: Double(i) / 25)
        }
        expect(SlouchTest.hold(moving, lastSeconds: 3, window: 1.5) == nil, "no hold while you keep moving")
    }

    test("limits land between your upright pose and your slouch") {
        let slouched = SlouchTest.Hold(gravity: gravity(pitchDegrees: 26), forwardCM: 12, dropCM: 1.2, spreadDegrees: 0.2)
        let upright = SlouchTest.Hold(gravity: gravity(pitchDegrees: 0.6), forwardCM: 0.5, dropCM: 0, spreadDegrees: 0.2)
        let o = SlouchTest.evaluate(calibration: cal, slouched: slouched, upright: upright)
        expect(o.neutralRefined, "upright poses agreed")
        // Neutral moves halfway to the second upright (0.3°): slouch 25.7°, upright 0.3° → 0.3 + 0.6 × 25.4.
        expectNear(o.forwardTilt ?? 0, 16, tolerance: 0.01, "tilt limit")
        // Shift: 0.6 × min(12 from the start, 11.5 from sitting back up) = 6.9 → 7.
        expectNear(o.shiftCM ?? 0, 7, tolerance: 0.01, "shift limit")
        expect(o.sawSlouch)
    }

    test("a big slouch loosens the limits, a subtle one tightens them, within bounds") {
        let upright = SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2)
        func slouch(_ pitch: Double, _ forward: Double, tiltLimit: Double = 15) -> SlouchTest.Outcome {
            SlouchTest.evaluate(calibration: cal, slouched: SlouchTest.Hold(gravity: gravity(pitchDegrees: pitch), forwardCM: forward,
                                                                           dropCM: 0, spreadDegrees: 0.2), upright: upright,
                                currentTiltLimit: tiltLimit)
        }
        let big = slouch(60, 30)
        expect(big.forwardTilt == 30 && big.shiftCM == 12, "capped at 30° / 12 cm: \(String(describing: big.forwardTilt)) \(String(describing: big.shiftCM))")
        expect(slouch(12, 2.5).forwardTilt == 10, "a 12° slouch gets the 10° minimum")
        // With a 10° tilt limit, tipping reads at most 2.1 cm, so the 3 cm minimum is safe.
        expect(slouch(0, 4.5, tiltLimit: 10).shiftCM == 3, "a 4.5 cm forward-head slouch gets the 3 cm minimum")
        // With 15°, tipping reads 3.1 cm: the limit can't go below 4 cm, which is too close to a 4.5 cm slouch.
        expect(slouch(0, 4.5).shiftCM == nil, "got \(String(describing: slouch(0, 4.5).shiftCM))")
    }

    test("a limit is never set at or above the slouch you just showed") {
        let upright = SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2)
        // 11° of tilt: the 10° minimum would sit right on it, so the slouch wouldn't reliably trip it.
        let o = SlouchTest.evaluate(calibration: cal, slouched: SlouchTest.Hold(gravity: gravity(pitchDegrees: 11), forwardCM: 2.3,
                                                                               dropCM: 0, spreadDegrees: 0.2), upright: upright)
        expect(o.forwardTilt == nil, "got \(String(describing: o.forwardTilt))")
        // 3.5 cm forward: the 3 cm minimum is too close to it.
        let s = SlouchTest.evaluate(calibration: cal, slouched: SlouchTest.Hold(gravity: g0, forwardCM: 3.5, dropCM: 0, spreadDegrees: 0.2),
                                    upright: upright)
        expect(s.shiftCM == nil, "got \(String(describing: s.shiftCM))")
    }

    test("a slouch that only tips the head doesn't set the head-shift limit") {
        // Tipping 26° on the neck reads as ~5.3 cm forward by itself (neck kinematics), with no real move.
        let pureTilt = SlouchTest.Hold(gravity: gravity(pitchDegrees: 26), forwardCM: 12 * sin(26 * .pi / 180),
                                       dropCM: 12 * (1 - cos(26 * .pi / 180)), spreadDegrees: 0.2)
        let o = SlouchTest.evaluate(calibration: cal, slouched: pureTilt,
                                    upright: SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2))
        expect(o.forwardTilt == 16, "tilt limit 0.6 × 26, got \(String(describing: o.forwardTilt))")
        expect(o.shiftCM == nil, "got \(String(describing: o.shiftCM))")
        expectNear(o.slouchShiftCM, 0, tolerance: 0.01, "no translation")
    }

    test("a slouch that barely moves the head keeps your limits") {
        let upright = SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2)
        let o = SlouchTest.evaluate(calibration: cal, slouched: SlouchTest.Hold(gravity: gravity(pitchDegrees: 5), forwardCM: 1.5, dropCM: 0.5, spreadDegrees: 0.2), upright: upright)
        expect(!o.sawSlouch && o.forwardTilt == nil && o.shiftCM == nil)
        // A forward-head slouch with level eyes still sets the shift limit (but not tilt).
        let level = SlouchTest.evaluate(calibration: cal, slouched: SlouchTest.Hold(gravity: g0, forwardCM: 6, dropCM: 0, spreadDegrees: 0.2), upright: upright)
        expect(level.forwardTilt == nil && level.shiftCM == 4, "shift only: \(String(describing: level.shiftCM))")
    }

    test("a shift that only shows on the way in (not undone on the way back) doesn't count") {
        // The estimate never came back down after sitting up: probably drift, not your slouch.
        let o = SlouchTest.evaluate(calibration: cal,
                                    slouched: SlouchTest.Hold(gravity: g0, forwardCM: 7, dropCM: 0, spreadDegrees: 0.2),
                                    upright: SlouchTest.Hold(gravity: g0, forwardCM: 6, dropCM: 0, spreadDegrees: 0.2))
        expect(o.shiftCM == nil, "got \(String(describing: o.shiftCM))")
    }

    test("the second upright pose refines neutral only when it agrees and isn't more slouched") {
        let slouched = SlouchTest.Hold(gravity: gravity(pitchDegrees: 25), forwardCM: 0, dropCM: 0, spreadDegrees: 0.2)
        func upright(_ pitch: Double, _ roll: Double = 0) -> SlouchTest.Outcome {
            SlouchTest.evaluate(calibration: cal, slouched: slouched,
                                upright: SlouchTest.Hold(gravity: gravity(pitchDegrees: pitch, rollDegrees: roll), forwardCM: 0,
                                                         dropCM: 0, spreadDegrees: 0.2))
        }
        let close = upright(0, 3)
        expect(close.neutralRefined)
        expectNear(degrees(close.calibration.neutralGravity, g0), 1.5, tolerance: 0.01, "halfway")
        expect(abs(simd_dot(close.calibration.forward, close.calibration.up)) < 1e-9, "forward re-orthogonalised")
        expect(degrees(close.calibration.forward, SIMD3(0, 1, 0)) < 0.1, "a roll shift doesn't swing the forward axis")
        // Not fully straightened after slouching: keep the first, deliberate pose (and don't nag about it).
        let lazy = upright(3)
        expect(!lazy.neutralRefined && !lazy.neutralInconsistent && lazy.calibration == cal, "3° forward: keep the first")
        let far = upright(-8)
        expect(!far.neutralRefined && far.neutralInconsistent && far.calibration == cal, "8° apart: keep the first and say so")
        expectNear(far.neutralRepeatDegrees, 8, tolerance: 0.01)
    }

    test("neutral uses the pose you adjusted into, not the one you held before") {
        // Held still at 6° (reading the prompt), then sat up and held still upright.
        let before = (0..<50).map { i in gravity(pitchDegrees: 6 + 0.05 * sin(Double(i))) }
        let adjusting = (0..<15).map { gravity(pitchDegrees: 6 - Double($0) * 0.4) }
        let after = (0..<40).map { i in gravity(pitchDegrees: 0.1 * sin(Double(i))) }
        guard case .success(let c) = HeadCalibration.solve(neutral: before + adjusting + after, lookDown: nod,
                                                             leverFit: LeverArmFit(), earbud: .left)
        else { return expect(false, "should succeed") }
        expect(degrees(c.neutralGravity, g0) < 0.2, "neutral \(degrees(c.neutralGravity, g0))° off")
    }

    test("review fix: the slouch-test shift limit never sits below what tipping to the tilt limit reads") {
        // Tilt limit 25° (kept): tipping that far reads 12·sin(25°) = 5.07 cm, so the limit must be 6, not 5.
        let o = SlouchTest.evaluate(calibration: cal,
                                    slouched: SlouchTest.Hold(gravity: gravity(pitchDegrees: 5), forwardCM: 7.2, dropCM: 0, spreadDegrees: 0.2),
                                    upright: SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2),
                                    currentTiltLimit: 25)
        expect(o.shiftCM == 6, "got \(String(describing: o.shiftCM))")
    }

    test("slouch test run: checks the signal and the holds before evaluating") {
        let slouch = samples(pitch: 25, forwardCM: 7, seconds: 6), tall = samples(pitch: 0, forwardCM: 0, seconds: 4)
        guard case .evaluated(let o) = SlouchTest.run(calibration: cal, slouch: slouch, sitTall: tall, currentTiltLimit: 15)
        else { return expect(false, "a clean test is evaluated") }
        expect(o.sawSlouch)
        let dropped = Array(slouch.suffix(40))                 // 6 s step, under 2 s of samples
        expect(SlouchTest.run(calibration: cal, slouch: dropped, sitTall: tall, currentTiltLimit: 15) == .signalDropped)
        let moving = (0..<150).map { i in
            SlouchTest.Sample(gravity: gravity(pitchDegrees: 20 * sin(Double(i) * 0.4)), forwardCM: 0, dropCM: 0, time: Double(i) / 25)
        }
        expect(SlouchTest.run(calibration: cal, slouch: moving, sitTall: tall, currentTiltLimit: 15) == .keptMoving)
    }

    test("review fix: a drop-only slouch still floors the shift limit at the forward reading of tipping") {
        // Head drops 6 cm, barely forward. Tipping to the 25° tilt limit reads 5.07 cm *forward*, and the
        // same limit applies to forward readings, so it can't be 4 cm.
        let o = SlouchTest.evaluate(calibration: cal,
                                    slouched: SlouchTest.Hold(gravity: g0, forwardCM: 0.5, dropCM: 8, spreadDegrees: 0.2),
                                    upright: SlouchTest.Hold(gravity: g0, forwardCM: 0, dropCM: 0, spreadDegrees: 0.2),
                                    currentTiltLimit: 25)
        expect(o.shiftCM == 6, "got \(String(describing: o.shiftCM))")
    }

    test("sit up straight ends once held, not before 3 s, not while wobbling") {
        let still = [SIMD3<Double>](repeating: g0, count: 60)
        expect(!HeadCalibration.recordsNeutral(at: 0.5), "the first moments are skipped")
        expect(!HeadCalibration.neutralIsHeld(still, phaseTime: 2.9), "not before 3 s")
        expect(HeadCalibration.neutralIsHeld(still, phaseTime: 3.2), "held")
        let wobbly = (0..<60).map { i in gravity(pitchDegrees: 3 * sin(Double(i) * 0.5)) }
        expect(!HeadCalibration.neutralIsHeld(wobbly, phaseTime: 5), "still moving")
        expect(!HeadCalibration.neutralIsHeld(Array(still.prefix(10)), phaseTime: 5), "too few samples")
    }
}

func lookDownTests() {
    print("Looking down vs. slouching")
    let rules = PostureRules(maxForwardTilt: 15, maxSideTilt: 12, maxShiftCM: 5)

    test("glancing at the keyboard is head-only; a real forward move or side tilt isn't") {
        // 30° glance: the neck model reads ~6 cm forward, but the head itself didn't move.
        let glance = PostureReading(tilt: 30, pitch: 30, forwardCM: 6.2, dropCM: 1.6, forwardMoveCM: 0.2, dropMoveCM: 0)
        let a = rules.assess(glance)
        expect(a.body.isEmpty, "body \(a.body)")
        expect(a.lookingDown.count == 2, "tilt + tilt-driven shift: \(a.lookingDown)")
        // Forward-head slouch with level eyes: real movement, counts right away.
        let poke = rules.assess(PostureReading(forwardCM: 6, forwardMoveCM: 6))
        expect(poke.body.count == 1 && poke.lookingDown.isEmpty)
        // Head tipped *and* really moved past the limit: the movement counts right away.
        let slump = rules.assess(PostureReading(tilt: 25, pitch: 25, forwardCM: 12, forwardMoveCM: 7))
        expect(slump.body.count == 1 && slump.lookingDown.count == 1, "\(slump)")
        // A shift from small tipping plus real movement isn't "looking down".
        let mixed = rules.assess(PostureReading(tilt: 5, pitch: 5, forwardCM: 5.5, forwardMoveCM: 4.5))
        expect(mixed.body.count == 1, "\(mixed)")
        // Review fix: a small chin tip (under the tilt limit) with real movement just under the limit is a
        // forward-head slouch, not a glance.
        let chinPoke = rules.assess(PostureReading(tilt: 8, pitch: 8, forwardCM: 6.6, forwardMoveCM: 4.9))
        expect(chinPoke.body.count == 1 && chinPoke.lookingDown.isEmpty, "\(chinPoke)")
        expect(!rules.assess(PostureReading(roll: 15)).body.isEmpty, "side tilt counts right away")
        // Review fix: a glance just short of the tilt limit plus a little drift is still a glance (tipping
        // 14° reads 2.9 cm; with 2.2 cm of drift that's over 5 cm, but most of it is the tip).
        let nearLimit = rules.assess(PostureReading(tilt: 14, pitch: 14, forwardCM: 5.1, forwardMoveCM: 2.2))
        expect(nearLimit.body.isEmpty && nearLimit.lookingDown.count == 1, "\(nearLimit)")
    }

    test("looking down only counts once it's held") {
        var g = LookDownGrace()
        g.graceSeconds = 30
        for s in 1...29 { expect(!g.tick(lookingDown: true), "second \(s) is still a glance") }
        expect(g.remaining == 1, "remaining \(String(describing: g.remaining))")
        expect(g.tick(lookingDown: true), "the 30th second counts (not the 31st)")
    }

    test("looking back up ends the glance, a one-second flick doesn't") {
        var g = LookDownGrace()
        g.graceSeconds = 10
        for _ in 0..<8 { _ = g.tick(lookingDown: true) }
        expect(g.remaining == 2, "remaining \(String(describing: g.remaining))")
        _ = g.tick(lookingDown: false)                     // a quick look at the screen
        expect(!g.tick(lookingDown: true))
        expect(g.tick(lookingDown: true), "the flick didn't restart the clock")
        _ = g.tick(lookingDown: false); _ = g.tick(lookingDown: false)   // really looked up
        expect(g.remaining == nil)
        for _ in 0..<9 { expect(!g.tick(lookingDown: true), "a fresh glance gets the full grace") }
        expect(g.tick(lookingDown: true))
    }

    test("grace 0 counts right away (the old behaviour)") {
        var g = LookDownGrace()
        g.graceSeconds = 0
        expect(g.tick(lookingDown: true))
    }

    test("regression: looking down pauses the slouch clock instead of resetting the streak") {
        // Mirrors PostureMonitor.tick: a 5-minute head-down slouch, a 2 s look up at the screen, then
        // head down again. The new grace window must not count as 30 s of good posture.
        var timer = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        var grace = LookDownGrace()
        let down = PostureReading(tilt: 25, pitch: 25, forwardCM: 5.1, dropCM: 1.1)
        let up = PostureReading()
        func tick(_ r: PostureReading) {
            let signal = PostureTick.assess(r, rules: rules, grace: &grace, hunched: false).signal
            if signal != .holding { _ = timer.tick(slouching: signal == .slouching) }
        }
        for _ in 0..<330 { tick(down) }
        let streak = timer.slouchSeconds
        expect(streak >= 290, "streak \(streak)")
        tick(up); tick(up)
        for _ in 0..<40 { tick(down) }
        expect(timer.slouchSeconds > streak, "streak kept and growing: \(timer.slouchSeconds) vs \(streak)")
        // Actually sitting well for 30 s still resets it.
        for _ in 0..<30 { tick(up) }
        expect(timer.slouchSeconds == 0)
    }

    test("readings are highlighted only when they count") {
        let glance = PostureReading(tilt: 30, pitch: 30, forwardCM: 6.2, dropCM: 1.6, forwardMoveCM: 0.2)
        let inGrace = rules.flags(for: glance, lookingDownCounts: false)
        expect(!inGrace.tilt && !inGrace.head, "a glance in its grace isn't flagged")
        let held = rules.flags(for: glance, lookingDownCounts: true)
        expect(held.tilt && held.head)
        let poke = rules.flags(for: PostureReading(forwardCM: 6, forwardMoveCM: 6), lookingDownCounts: false)
        expect(!poke.tilt && poke.head, "real movement is flagged right away")
        expect(rules.flags(for: PostureReading(roll: 15), lookingDownCounts: false).tilt, "side tilt right away")
    }

    test("review fix: the start of a glance isn't flagged before the grace runs out") {
        var g = LookDownGrace()
        g.graceSeconds = 3
        expect(!g.hasRunOut, "upright: a new glance doesn't count yet")
        _ = g.tick(lookingDown: true); _ = g.tick(lookingDown: true)
        expect(!g.hasRunOut, "2 s in")
        _ = g.tick(lookingDown: true)
        expect(g.hasRunOut, "3 s in")
        _ = g.tick(lookingDown: false)
        expect(!g.hasRunOut, "looking back up: readings aren't flagged on the way up")
        _ = g.tick(lookingDown: true)
        expect(g.hasRunOut, "a one-second flick up doesn't end the episode")
        _ = g.tick(lookingDown: false); _ = g.tick(lookingDown: false)
        expect(!g.hasRunOut, "looked back up: the next glance starts fresh")
        var none = LookDownGrace()
        none.graceSeconds = 0
        expect(none.hasRunOut, "grace 0: looking down always counts")
    }

    test("tick verdict: countdown only while holding, hunch counts, stats-ready signal") {
        let glance = PostureReading(tilt: 30, pitch: 30, forwardCM: 6.2, dropCM: 1.6, forwardMoveCM: 0.2)
        var g = LookDownGrace()
        let held = PostureTick.assess(glance, rules: rules, grace: &g, hunched: false)
        expect(held.signal == .holding && held.reasons.isEmpty && held.lookDownRemaining == 29, "\(held)")
        // Tipped forward *and* tilted sideways: already slouching, so no "counts in Xs" countdown.
        var g2 = LookDownGrace()
        let both = PostureTick.assess(PostureReading(tilt: 30, pitch: 30, roll: 15, forwardCM: 6.2, forwardMoveCM: 0.2),
                                      rules: rules, grace: &g2, hunched: false)
        expect(both.signal == .slouching && both.lookDownRemaining == nil && both.lookingDown, "\(both)")
        var g3 = LookDownGrace()
        let hunch = PostureTick.assess(PostureReading(), rules: rules, grace: &g3, hunched: true)
        expect(hunch.reasons == ["shoulders hunched"] && hunch.signal == .slouching)
        var g4 = LookDownGrace()
        expect(PostureTick.assess(PostureReading(), rules: rules, grace: &g4, hunched: false).signal == .good)
    }
}
