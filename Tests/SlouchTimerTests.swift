import Foundation

func slouchTimerTests() {
    print("SlouchTimer")

    test("slouching counts up; good posture alone does nothing") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        for _ in 0..<50 { _ = t.tick(slouching: false) }
        expect(t.slouchSeconds == 0)
        for _ in 0..<12 { _ = t.tick(slouching: true) }
        expect(t.slouchSeconds == 12, "got \(t.slouchSeconds)")
    }

    test("brief corrections don't reset the streak") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        for _ in 0..<60 { _ = t.tick(slouching: true) }
        for _ in 0..<10 { _ = t.tick(slouching: false) }
        expect(t.slouchSeconds == 70, "clock keeps running during a short correction, got \(t.slouchSeconds)")
        expect(t.recoveryProgress != nil, "should report recovery progress")
        for _ in 0..<5 { _ = t.tick(slouching: true) }
        expect(t.slouchSeconds == 75)
        expect(t.recoveryProgress == nil, "slouching again cancels recovery")
    }

    test("sustained good posture resets the streak") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        for _ in 0..<60 { _ = t.tick(slouching: true) }
        for _ in 0..<30 { _ = t.tick(slouching: false) }
        expect(t.slouchSeconds == 0, "got \(t.slouchSeconds)")
        expect(t.recoveryProgress == nil)
    }

    test("recovery progress climbs from 0 to 1") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        for _ in 0..<5 { _ = t.tick(slouching: true) }
        _ = t.tick(slouching: false)
        expectNear(t.recoveryProgress ?? -1, 1.0 / 30, tolerance: 1e-9)
        for _ in 0..<14 { _ = t.tick(slouching: false) }
        expectNear(t.recoveryProgress ?? -1, 0.5, tolerance: 1e-9)
    }

    test("alerts fire at 10 minutes and every 10 minutes after") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        var alerts: [Int] = []
        for s in 1...1800 where t.tick(slouching: true) { alerts.append(s) }
        expect(alerts == [600, 1200, 1800], "got \(alerts)")
    }

    test("no alert fires while you're sitting well") {
        var t = SlouchTimer(alertSeconds: 600, recoverySeconds: 30)
        for _ in 0..<599 { _ = t.tick(slouching: true) }
        // Second 600 lands during a brief correction: no alert now...
        expect(t.tick(slouching: false) == false)
        // ...but it fires as soon as you slouch again.
        expect(t.tick(slouching: true) == true)
    }

    test("alert counter resets with the streak") {
        var t = SlouchTimer(alertSeconds: 60, recoverySeconds: 5)
        var count = 0
        for _ in 0..<60 where t.tick(slouching: true) { count += 1 }
        for _ in 0..<5 { _ = t.tick(slouching: false) }
        for _ in 0..<60 where t.tick(slouching: true) { count += 1 }
        expect(count == 2, "a fresh streak should alert again, got \(count)")
    }
}
