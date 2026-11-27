import AppKit
import AVFoundation
import Foundation

@MainActor
func dingTests() {
    print("Dings & alert sounds")

    test("the ding plays exactly the chosen number of seconds after the slouch is detected") {
        for delay in [0, 1, 3, 5, 12] {
            var rule = SlouchDingRule()
            rule.holdSeconds = delay
            let t0 = Date()
            var dingAt: Int?
            for s in 0..<40 where rule.tick(slouching: true, now: t0 + Double(s)) { dingAt = s }
            expect(dingAt == delay, "delay \(delay) s → dinged \(dingAt.map { "\($0) s" } ?? "never") after detection")
        }
    }

    test("review fix: a look-down pause between two slouches doesn't shorten the ding delay") {
        var rule = SlouchDingRule()
        rule.holdSeconds = 5
        let t0 = Date()
        for s in 0..<3 { expect(!rule.tick(slouching: true, now: t0 + Double(s))) }     // 3 s of a side tilt
        for _ in 0..<20 { rule.hold() }                                                // then 20 s looking down
        var dingAt: Int?
        for s in 0..<20 where rule.tick(slouching: true, now: t0 + 30 + Double(s)) { dingAt = s }
        expect(dingAt == 5, "dinged \(dingAt.map { "\($0) s" } ?? "never") into the new slouch, not after 5 s")
    }

    test("review fix: good posture split by a look-down pause doesn't add up to re-arming") {
        var rule = SlouchDingRule()
        rule.holdSeconds = 0
        let t0 = Date()
        expect(rule.tick(slouching: true, now: t0), "first slouch dings")
        for s in 1...5 { _ = rule.tick(slouching: false, now: t0 + Double(s)) }          // 5 s good
        for _ in 0..<20 { rule.hold() }                                                 // 20 s looking down
        for s in 26...30 { _ = rule.tick(slouching: false, now: t0 + Double(s)) }       // 5 s good
        expect(!rule.tick(slouching: true, now: t0 + 31), "only 5 s in a row of good posture: no new ding")
        for s in 32...42 { _ = rule.tick(slouching: false, now: t0 + Double(s)) }       // 11 s good in a row
        expect(rule.tick(slouching: true, now: t0 + 43), "a real 10 s of good posture re-arms it")
    }

    test("one ding per slouch, however long it lasts") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dings = 0
        for s in 0..<600 where rule.tick(slouching: true, now: t0 + Double(s)) { dings += 1 }
        expect(dings == 1, "got \(dings)")
    }

    test("regression: slouching again after sitting well dings again (no 2-minute silence)") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dingTimes: [Int] = []
        // slouch 20 s, sit well 15 s, slouch again 20 s, sit well 12 s, slouch again
        let pattern = [(true, 20), (false, 15), (true, 20), (false, 12), (true, 10)]
        var s = 0
        for (slouching, seconds) in pattern {
            for _ in 0..<seconds {
                if rule.tick(slouching: slouching, now: t0 + Double(s)) { dingTimes.append(s) }
                s += 1
            }
        }
        expect(dingTimes == [1, 36, 68], "a ding for each new slouch, 1 s after it starts (got \(dingTimes))")
    }

    test("hovering right at the limit doesn't nag") {
        var rule = SlouchDingRule()
        let t0 = Date()
        var dings = 0
        for s in 0..<180 where rule.tick(slouching: (s / 3) % 2 == 0, now: t0 + Double(s)) { dings += 1 }  // in/out every 3 s
        expect(dings == 1, "3 minutes of flickering in and out → \(dings) ding(s)")
    }

    test("the ding is a valid, short, gentle sound") {
        let data = Chime.wav(notes: [(1318.5, 0)], length: 0.9, volume: 0.4)
        expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        expect(data.count == 44 + Int(0.9 * 44_100) * 2)
        let samples: [Int16] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        expect(peak > 6_000 && peak < 24_000, "clearly audible but not harsh (peak \(peak) of 32767)")
        expect(abs(Int(samples.last!)) < 50, "fades out without a click")
        expect(Chime.gentle != nil, "macOS can play the ding")
    }

    test("the slouch alert is spoken out loud") {
        let u = Chime.alertUtterance()
        expect(u.speechString == Chime.alertWord && !Chime.alertWord.isEmpty, "says \(u.speechString)")
        expect(u.volume > 0 && u.volume <= 1, "audible (volume \(u.volume))")
        expect(Chime.canSpeak, "macOS has a voice to say it with")
    }
}
