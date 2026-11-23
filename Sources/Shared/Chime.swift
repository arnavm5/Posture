import AppKit
import Foundation

/// Soft bell sounds, synthesized in the app (so they're consistent and play even when
/// notification sounds are muted).
@MainActor
enum Chime {
    /// One gentle, short ding: "you've started slouching".
    static let gentle = sound(notes: [(1318.5, 0)], length: 0.9, volume: 0.4)             // E6
    /// Two rising notes, a little brighter: "you've been slouching for a while".
    static let alert = sound(notes: [(987.8, 0), (1318.5, 0.16)], length: 1.3, volume: 0.45)  // B5 → E6

    static func playGentle() { play(gentle) }
    static func playAlert() { play(alert) }

    private static func play(_ s: NSSound?) {
        guard let s else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }

    private static func sound(notes: [(Double, Double)], length: Double, volume: Double) -> NSSound? {
        NSSound(data: wav(notes: notes, length: length, volume: volume))
    }

    /// 16-bit mono WAV of a soft bell: a fundamental plus quickly fading overtones, gentle attack, long decay.
    nonisolated static func wav(notes: [(frequency: Double, start: Double)], length: Double, volume: Double,
                                sampleRate: Int = 44_100) -> Data {
        let n = Int(length * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            for (f, start) in notes where t >= start {
                let u = t - start
                let attack = min(1, u / 0.006)
                let tone = sin(2 * .pi * f * u)
                    + 0.35 * sin(2 * .pi * 2 * f * u) * exp(-u * 6)
                    + 0.12 * sin(2 * .pi * 3.01 * f * u) * exp(-u * 10)
                v += tone * attack * exp(-u * 4.2)
            }
            let fadeOut = min(1, (length - t) / 0.05)            // no click at the end
            samples[i] = Int16(max(-1, min(1, v * volume / 1.5 * fadeOut)) * 32_000)
        }
        var d = Data()
        func put<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = n * 2
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

/// Decides when to play the "you've started slouching" ding.
///
/// - It plays `holdSeconds` after a slouch is first detected (0 = right away).
/// - Once per slouch: every *new* slouch dings, and a slouch counts as new once you've sat well for
///   `resetAfterGood` seconds. Hovering right at the limit (in and out every few seconds) doesn't nag.
struct SlouchDingRule {
    var holdSeconds = 1
    var resetAfterGood = 10
    private var run = 0
    private var goodRun = 0
    private var armed = true
    private(set) var lastDing: Date?

    /// Call once per second. Returns true when the ding should play.
    mutating func tick(slouching: Bool, now: Date) -> Bool {
        guard slouching else {
            run = 0
            goodRun += 1
            if goodRun >= resetAfterGood { armed = true }
            return false
        }
        goodRun = 0
        run += 1                                            // 1 on the tick the slouch is detected
        guard armed, run > holdSeconds else { return false }
        armed = false
        lastDing = now
        return true
    }
}
