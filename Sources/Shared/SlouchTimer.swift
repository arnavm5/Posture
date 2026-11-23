import Foundation

/// The forgiving slouch clock, ticked once per second.
///
/// - Slouching starts (or continues) the streak.
/// - Brief corrections don't reset it: the clock keeps running until you've held good posture for
///   `recoverySeconds` in a row, then it resets.
/// - An alert fires after `alertSeconds` of streak, then again every `alertSeconds` — but only
///   while you're actually slouching at that moment.
struct SlouchTimer {
    var alertSeconds: Int
    var recoverySeconds: Int

    private(set) var slouchSeconds = 0
    private(set) var goodRun = 0
    private(set) var alertsSent = 0

    init(alertSeconds: Int = 600, recoverySeconds: Int = 30) {
        self.alertSeconds = alertSeconds
        self.recoverySeconds = recoverySeconds
    }

    /// Sitting well after a slouch: 0…1 until the streak resets. `nil` when not recovering.
    var recoveryProgress: Double? {
        guard slouchSeconds > 0, goodRun > 0 else { return nil }
        return min(1, Double(goodRun) / Double(max(1, recoverySeconds)))
    }

    /// Advances one second. Returns `true` when an alert should fire.
    mutating func tick(slouching: Bool) -> Bool {
        if slouching {
            goodRun = 0
            slouchSeconds += 1
        } else {
            goodRun += 1
            if slouchSeconds > 0 {
                if goodRun >= recoverySeconds { reset() } else { slouchSeconds += 1 }
            }
        }
        guard slouching, slouchSeconds >= alertSeconds * (alertsSent + 1) else { return false }
        alertsSent += 1
        return true
    }

    mutating func reset() {
        slouchSeconds = 0
        goodRun = 0
        alertsSent = 0
    }
}
