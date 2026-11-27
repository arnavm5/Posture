import AppKit
import AVFoundation
import Foundation

/// The app's own alert sounds (played by the app, so they work even when notification sounds are muted):
/// a soft synthesized bell for "you've started slouching", and a spoken word for the slouch alert.
@MainActor
enum Chime {
    /// One gentle, short ding: "you've started slouching".
    static let gentle = sound(notes: [(1318.5, 0)], length: 0.9, volume: 0.4)             // E6
    /// Said out loud (text to speech) with the slouch alert: "you've been slouching for a while".
    static let alertWord = "grumble"

    private static let speech = AVSpeechSynthesizer()

    static func playGentle() { play(gentle) }

    /// Says the alert word. Returns false if it can't (no speech voice installed), so the caller can fall
    /// back to the notification's own sound rather than stay silent.
    @discardableResult
    static func playAlert() -> Bool {
        guard canSpeak else { return false }
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        speech.speak(alertUtterance())
        return true
    }

    /// At least one text-to-speech voice is installed.
    static var canSpeak: Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }

    /// The spoken alert, in the system voice.
    static func alertUtterance() -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: alertWord)
        u.volume = 0.7
        return u
    }

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

    /// Call instead of `tick` on a second the slouch clock is holding (looking down within its grace): it
    /// isn't slouching, so a slouch after it is detected afresh and waits its full `holdSeconds`; it isn't
    /// sitting well either, so re-arming needs `resetAfterGood` seconds of good posture in a row after it.
    mutating func hold() {
        run = 0
        goodRun = 0
    }

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
