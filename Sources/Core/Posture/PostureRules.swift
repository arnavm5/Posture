import Foundation

/// What counts as slouching, as a pure function so it can be tested.
/// Forward and side tilt have separate limits (from the calibrated head frame).
struct PostureRules {
    var maxForwardTilt: Double
    var maxSideTilt: Double
    var maxShiftCM: Double

    /// Every reason, whatever its kind.
    func reasons(for r: PostureReading) -> [String] {
        let a = assess(r)
        return a.body + a.lookingDown
    }

    /// Reasons, split by what AirPods can tell apart.
    ///  - `body`: the head really moved forward or down, or tilted sideways. These count right away.
    ///  - `lookingDown`: only the head tipped forward. A glance at the keyboard with a straight back looks
    ///    exactly like this (AirPods can't see your back), so these count only once held (`LookDownGrace`).
    func assess(_ r: PostureReading) -> (body: [String], lookingDown: [String]) {
        var body: [String] = [], down: [String] = []
        let c = checks(r)
        if c.forwardTilt { down.append("head tipped forward \(Int(r.pitch))°") }
        if c.sideTilt { body.append("head tilted \(r.roll > 0 ? "left" : "right") \(Int(abs(r.roll)))°") }
        if c.forward {
            let reason = String(format: "head %.0f cm forward", r.forwardCM)
            if c.forwardIsTipping { down.append(reason) } else { body.append(reason) }
        }
        if c.drop {
            let reason = String(format: "head %.0f cm lower", r.dropCM)
            if c.dropIsTipping { down.append(reason) } else { body.append(reason) }
        }
        return (body, down)
    }

    /// Whether the tilt and head-position readings count against you right now, for highlighting them:
    /// body reasons always do, looking-down ones only once `lookingDownCounts` (their grace has run out).
    func flags(for r: PostureReading, lookingDownCounts: Bool) -> (tilt: Bool, head: Bool) {
        let c = checks(r)
        let tilt = c.sideTilt || (c.forwardTilt && lookingDownCounts)
        let forward = c.forward && (!c.forwardIsTipping || lookingDownCounts)
        let drop = c.drop && (!c.dropIsTipping || lookingDownCounts)
        return (tilt, forward || drop)
    }

    /// Each limit, and whether a shift over its limit is just the head tipping (so it gets the look-down grace).
    /// It is when the real movement alone wouldn't break the limit and either the head is tipped past the
    /// forward-tilt limit (the same look-down) or tipping is most of the shift. A glance just short of the tilt
    /// limit plus a little drift is still a glance; a small chin tip with real movement near the limit is a
    /// forward-head slouch.
    private func checks(_ r: PostureReading) -> (forwardTilt: Bool, sideTilt: Bool, forward: Bool, forwardIsTipping: Bool,
                                                drop: Bool, dropIsTipping: Bool) {
        let forwardTilt = r.pitch > maxForwardTilt
        let sideTilt = abs(r.roll) > maxSideTilt
        let forward = r.forwardCM > maxShiftCM
        let drop = r.dropCM > maxShiftCM
        return (forwardTilt, sideTilt,
                forward, isTipping(total: r.forwardCM, move: r.forwardMoveCM, tiltedPastLimit: forwardTilt),
                drop, isTipping(total: r.dropCM, move: r.dropMoveCM, tiltedPastLimit: forwardTilt))
    }

    private func isTipping(total: Double, move: Double, tiltedPastLimit: Bool) -> Bool {
        let fromTipping: Double = total - move
        return move <= maxShiftCM && (tiltedPastLimit || fromTipping > move)
    }
}

/// What one tick means for the slouch clock and the ding.
enum SlouchSignal: Equatable {
    case good, slouching
    /// Only head-only reasons, still in their grace: not slouching yet, but not sitting well either. The
    /// slouch clock and the ding wait. Counting it as good posture would let every glance-length look-down
    /// wipe a slouch streak (the grace and the clock's recovery are both ~30 s).
    case holding

    static func from(reasons: [String], lookingDownInGrace: Bool) -> SlouchSignal {
        if !reasons.isEmpty { return .slouching }
        return lookingDownInGrace ? .holding : .good
    }
}

/// Glancing down at your keyboard tips your head just like a head-down slouch, and AirPods can't see your
/// back. What differs is time: a glance is brief and you look back up; a slouch stays. So head-only reasons
/// count once your head has stayed down for `graceSeconds`. Looking back up for `resetSeconds` ends the
/// episode (a one-second flick up doesn't, so a slouch with the odd glance at the screen still counts).
struct LookDownGrace {
    var graceSeconds = 30
    var resetSeconds = 2
    private(set) var downSeconds = 0
    private var upSeconds = 0

    /// Seconds left before looking down counts as slouching (nil when you aren't looking down).
    var remaining: Int? { downSeconds > 0 && upSeconds == 0 ? max(0, graceSeconds - downSeconds) : nil }

    /// Whether looking down counts right now: the grace has run out for this episode and you haven't started
    /// looking back up. Unlike `remaining`, this is right between ticks too (it's false at the start of a
    /// glance, before the tick that notices it). With no grace, looking down always counts.
    var hasRunOut: Bool { graceSeconds == 0 || (downSeconds >= graceSeconds && upSeconds == 0) }

    /// One 1 Hz tick. Returns true when head-only reasons should count as slouching (from the
    /// `graceSeconds`-th second of looking down; right away when it's 0).
    mutating func tick(lookingDown: Bool) -> Bool {
        if lookingDown {
            downSeconds += 1
            upSeconds = 0
            return downSeconds >= graceSeconds
        }
        upSeconds += 1
        if upSeconds >= resetSeconds { downSeconds = 0 }
        return false
    }

    mutating func reset() {
        downSeconds = 0
        upSeconds = 0
    }
}

/// What one 1 Hz tick of readings adds up to: the reasons that count right now and what they mean for the
/// slouch clock, the ding and today's stats. `PostureMonitor.tick()` runs exactly this.
struct PostureTick: Equatable {
    /// Reasons that count as slouching now (body reasons, looking-down ones once held, a hunch).
    var reasons: [String]
    var signal: SlouchSignal
    /// Any head-only reason, counted or not (neutral-pose adaptation waits while you look down).
    var lookingDown: Bool
    /// Seconds until looking down counts, shown only while the clock is holding for it.
    var lookDownRemaining: Int?

    static func assess(_ r: PostureReading, rules: PostureRules, grace: inout LookDownGrace, hunched: Bool) -> PostureTick {
        let a = rules.assess(r)
        let lookingDown = !a.lookingDown.isEmpty
        let downCounts = grace.tick(lookingDown: lookingDown)
        var reasons = a.body + (downCounts ? a.lookingDown : [])
        if hunched { reasons.append("shoulders hunched") }
        let signal = SlouchSignal.from(reasons: reasons, lookingDownInGrace: lookingDown && !downCounts)
        return PostureTick(reasons: reasons, signal: signal, lookingDown: lookingDown,
                           lookDownRemaining: signal == .holding ? grace.remaining : nil)
    }
}
