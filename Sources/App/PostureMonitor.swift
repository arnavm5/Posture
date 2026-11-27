import Foundation
import os
import ServiceManagement
import SwiftUI
import simd

enum PostureState: Equatable {
    case noAirPods, needsCalibration, calibrating, good, slouching, paused

    var symbol: String {
        switch self {
        case .noAirPods: "airpods"
        case .needsCalibration, .calibrating: "scope"
        case .good: "figure.stand"
        case .slouching: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        }
    }

    var label: String {
        switch self {
        case .noAirPods: "Waiting for AirPods…"
        case .needsCalibration: "Calibrate to start"
        case .calibrating: "Calibrating…"
        case .good: "Good posture"
        case .slouching: "Slouching"
        case .paused: "Paused"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .slouching: .orange
        case .calibrating, .needsCalibration: .blue
        default: .secondary
        }
    }
}

@MainActor
final class PostureMonitor: ObservableObject {
    static let log = Logger(subsystem: "local.posture.app", category: "Posture")
    // Live readout
    @Published private(set) var state: PostureState = .noAirPods
    @Published private(set) var reading = PostureReading()
    @Published private(set) var slouchReasons: [String] = []
    @Published private(set) var slouchSeconds = 0
    @Published private(set) var goodSecondsToday = 0
    @Published private(set) var badSecondsToday = 0
    // Standing desk
    @Published private(set) var deskMode: DeskMode = .sitting
    @Published private(set) var sittingSecondsToday = 0
    @Published private(set) var standingSecondsToday = 0
    /// Hunch model performance (for the Hunch Model window).
    @Published private(set) var hunchReport = HunchReport()
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var calibrationPrompt: String?
    @Published private(set) var calibrationStep: (index: Int, of: Int)?
    @Published private(set) var calibrationError: String?
    /// Non-blocking suggestion, e.g. after the AirPods were taken out and put back in.
    @Published private(set) var calibrationHint: String?
    @Published private(set) var alertCount = 0          // bumps each time an alert fires (notch reacts)
    @Published private(set) var recoveryProgress: Double?   // sitting well after a slouch: 0…1 until the timer resets
    @Published private(set) var activeEarbud: Earbud = .unknown
    /// How far the neutral pose has followed small AirPod shifts since calibration (degrees).
    @Published private(set) var neutralDriftDegrees = 0.0
    // Hunched-shoulder detection (head pattern + your personal model)
    @Published private(set) var isHunched = false
    /// Head tipped forward only (e.g. at the keyboard): seconds left before it counts as slouching.
    @Published private(set) var lookDownRemaining: Int?
    /// Looking down counts as slouching right now (its grace has run out this episode).
    @Published private(set) var lookingDownCounts = false
    @Published private(set) var hunchSummary = ""
    /// Short confirmation after you label a moment (clears itself after a few seconds).
    @Published private(set) var hunchFeedback: (text: String, ok: Bool)?
    /// Bumps when the notch should briefly open to show feedback (e.g. a check-in answered from a notification).
    @Published private(set) var notchFlashCount = 0
    private var feedbackClear: DispatchWorkItem?
    // Display-only: head movement since last zeroed (e.g. standing up). Never affects posture.
    @Published private(set) var relativeUpCM = 0.0
    @Published private(set) var relativeHorizontalCM = 0.0
    @Published private(set) var relativeSigmaCM = 0.0
    @Published private(set) var relativeApproximate = false

    // Settings (persisted)
    @AppStorage("tiltThreshold") var forwardTiltThreshold: Double = 15 { willSet { objectWillChange.send() } }
    @AppStorage("sideTiltThreshold") var sideTiltThreshold: Double = 12 { willSet { objectWillChange.send() } }
    @AppStorage("shiftThresholdCM") var shiftThresholdCM: Double = 5 { willSet { objectWillChange.send() } }
    // Separate limits while standing (a standing desk's screen usually sits lower, and you move more).
    @AppStorage("standingTiltThreshold") var standingForwardTiltThreshold: Double = 18 { willSet { objectWillChange.send() } }
    @AppStorage("standingSideTiltThreshold") var standingSideTiltThreshold: Double = 12 { willSet { objectWillChange.send() } }
    @AppStorage("standingShiftThresholdCM") var standingShiftThresholdCM: Double = 6 { willSet { objectWillChange.send() } }
    @AppStorage("alertMinutes") var alertMinutes: Double = 10 { willSet { objectWillChange.send() } }
    @AppStorage("recoverySeconds") var recoverySeconds: Double = 30 { willSet { objectWillChange.send() } }
    @AppStorage("showInNotch") var showInNotch = true { willSet { objectWillChange.send() } }
    @AppStorage("hunchCheckIns") var hunchCheckIns = true { willSet { objectWillChange.send() } }
    @AppStorage("followAirPodShifts") var followAirPodShifts = true { willSet { objectWillChange.send() } }
    @AppStorage("dingOnSlouch") var dingOnSlouch = true { willSet { objectWillChange.send() } }
    /// Seconds after a slouch is detected before the gentle ding plays.
    @AppStorage("dingDelay") var dingDelaySeconds: Double = 1 { willSet { objectWillChange.send() } }
    @AppStorage("chimeOnAlert") var chimeOnAlert = true { willSet { objectWillChange.send() } }
    /// Calibration includes the quick slouch test that sets your limits.
    @AppStorage("slouchTestOnCalibrate") var slouchTestOnCalibrate = true { willSet { objectWillChange.send() } }
    /// How long the head may stay tipped forward (with no real movement) before it counts as slouching.
    @AppStorage("lookDownGraceSeconds") var lookDownGraceSeconds: Double = 30 { willSet { objectWillChange.send() } }

    private let motion = HeadphoneMotion()
    private var spikeFilter = SpikeFilter()
    private var compensator = LeverArmCompensator()
    private var worldFrame = WorldFrame()
    private var positionTracker = RelativePositionTracker()
    private var deskTracker = RelativePositionTracker()      // separate from the display one (Zero doesn't affect it)
    private var deskDetector = DeskModeDetector()
    private var estimator: PostureEstimator?
    private var smoothedGravity: SIMD3<Double>?
    private var timer: Timer?
    private var lastPublish = Date.distantPast
    private var lastPositionPublish = Date.distantPast
    private var hadDisconnect = false
    private var lastMotionDate: Date?
    static let positionResetGap: TimeInterval = 120

    // Calibration: the running sequence (all its logic is in Core), and a counter so a stale step timer is ignored.
    private var session: CalibrationSession?
    private var calibrationRun = 0

    private var slouchTimer = SlouchTimer()
    private var dingRule = SlouchDingRule()
    private var lookDown = LookDownGrace()
    private var hunch = HunchDetector()
    private var hunchLearner = HunchLearner()
    private var lastCheckIn = Date()          // wait a while after launch before the first question
    private var pendingCheckIn: (trace: [PostureReading], asked: Date)?
    private var trainingGeneration = 0
    static let checkInInterval: TimeInterval = 20 * 60
    private var statsDay = Calendar.current.startOfDay(for: Date())

    init() {
        migrateLegacyCalibration()
        // Load your saved calibration right away: some headphones never report which earbud the data
        // comes from, and then no earbud switch would ever trigger loading it.
        if let cal = HeadCalibration.best(for: .unknown, mode: deskMode) { apply(cal) }
        // Check-in buttons and answers must work from launch (only the permission prompt is deferred).
        Notifier.configure()
        retrainHunchModel()           // train from saved answers without blocking launch
        hunchSummary = hunchLearner.summary
        hunchReport = hunchLearner.report
        Notifier.onCheckInAnswer = { [weak self] hunched in
            MainActor.assumeIsolated { self?.answerCheckIn(hunched) }
        }
        motion.onSample = { [weak self] in self?.onMotion($0) }
        // Brief Bluetooth dropouts don't wipe your position; a real break (2+ minutes without data) does.
        motion.onDisconnect = { [weak self] in
            self?.hadDisconnect = true
            // Nothing may be differenced or filtered across the dropout.
            self?.spikeFilter.reset()
            self?.compensator.reset()
        }
        motion.onConnect = { [weak self] in
            guard let self, self.hadDisconnect, self.estimator != nil else { return }
            self.calibrationHint = "AirPods were put back in. Recalibrate if the readings look off."
        }
        motion.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var isCalibrated: Bool { estimator != nil }
    var airPodsMotionSupported: Bool { motion.isAvailable }
    var airPodsStreaming: Bool { motion.isStreaming }
    var alertSeconds: Int { Int(alertMinutes * 60) }
    var leverArmFitted: Bool { estimator?.calibration.leverFitted ?? false }

    // MARK: Motion (~25 Hz)

    private func onMotion(_ s: HeadphoneMotion.Sample) {
        if let last = lastMotionDate, Date().timeIntervalSince(last) > Self.positionResetGap { estimator?.resetPosition() }
        lastMotionDate = Date()
        if s.earbud != activeEarbud {
            // Mixing two earbuds' readings would produce a wrong calibration.
            if session != nil { failCalibration("Your AirPods switched earbuds during calibration. Try again.") }
            switchEarbud(to: s.earbud)
        }

        // 0. Clean the raw stream: replace one-sample glitches, flag dropped-sample gaps.
        guard let c = spikeFilter.push(MotionSample(gravity: s.gravity, accel: s.userAccel * 9.81, omega: s.rotationRate,
                                                    rotation: s.rotation, dt: s.dt)) else { return }
        if c.gap { compensator.reset() }

        // 1. Remove the earbud's swing around the neck (needs the gyro + calibrated lever arm).
        guard let k = compensator.step(gravity: c.gravity, accel: c.accel, omega: c.omega,
                                       rotation: c.rotation, dt: c.dt) else { return }
        let g = k.gravity
        if let previous: SIMD3<Double> = smoothedGravity {
            smoothedGravity = previous + (g - previous) * 0.08
        } else {
            smoothedGravity = g
        }

        // 2. Position trackers (world frame): the display-only one, and the sitting/standing detector.
        let world = worldFrame.toWorld(k.translational, gravity: g, rotation: k.rotation)
        positionTracker.ingest(worldAccel: world, rotationRate: simd_length(k.omega), dt: k.dt)
        deskTracker.ingest(worldAccel: world, rotationRate: simd_length(k.omega), dt: k.dt)
        if session == nil, deskDetector.update(heightCM: deskTracker.upCM, moving: deskTracker.moving) {
            deskModeChanged()
        }
        if Date().timeIntervalSince(lastPositionPublish) > 0.1 {
            relativeUpCM = positionTracker.upCM
            relativeHorizontalCM = positionTracker.horizontalCM
            relativeSigmaCM = max(positionTracker.upSigmaCM, positionTracker.horizontalSigmaCM)
            relativeApproximate = positionTracker.approximate
            lastPositionPublish = Date()
        }

        // 3. Calibration recording, or posture estimation.
        if session != nil {
            record(k)
            return
        }
        guard var est = estimator, let sg = smoothedGravity else { return }
        est.ingest(gravity: g, translational: k.translational, omega: k.omega, dt: k.dt)
        estimator = est
        let r = est.reading(gravity: sg)
        if Date().timeIntervalSince(lastPublish) > 0.1 {      // UI at 10 Hz
            reading = r
            lastPublish = Date()
        }
    }

    /// Each AirPod sits differently, so each has its own calibration.
    private func switchEarbud(to earbud: Earbud) {
        let first = activeEarbud == .unknown && estimator == nil
        activeEarbud = earbud
        if let cal = HeadCalibration.best(for: earbud, mode: deskMode) {
            apply(cal, keepPosition: true)          // same head, same posture: just another earbud
        } else if !first, estimator != nil {
            estimator = nil
            calibrationHint = "Now using your \(earbud == .left ? "left" : "right") AirPod. Calibrate it once."
        }
    }

    // MARK: Standing desk

    /// You corrected the sitting/standing detection by hand.
    func setDeskMode(_ mode: DeskMode) {
        guard mode != deskMode, session == nil else { return }     // a calibration belongs to one position
        deskDetector.set(mode, heightCM: deskTracker.upCM)
        deskModeChanged()
    }

    /// Switching between sitting and standing: fresh start, and use that position's calibration and limits.
    private func deskModeChanged() {
        deskMode = deskDetector.mode
        resetStreak()
        hunch.reset()
        if let cal = HeadCalibration.load(for: activeEarbud, mode: deskMode) ?? HeadCalibration.load(for: .unknown, mode: deskMode) {
            apply(cal)
            if calibrationHint?.contains("standing") == true { calibrationHint = nil }
        } else {
            estimator?.resetPosition()
            if deskMode == .standing, estimator != nil {
                calibrationHint = "You're standing. Calibrate once while standing for accurate standing checks (using your sitting calibration until then)."
            }
        }
    }

    /// Limits for the current position (sitting or standing).
    var rules: PostureRules {
        deskMode == .standing
            ? PostureRules(maxForwardTilt: standingForwardTiltThreshold, maxSideTilt: standingSideTiltThreshold, maxShiftCM: standingShiftThresholdCM)
            : PostureRules(maxForwardTilt: forwardTiltThreshold, maxSideTilt: sideTiltThreshold, maxShiftCM: shiftThresholdCM)
    }

    /// The settings steppers edit the limits of whichever position you're in.
    var maxForwardTilt: Double {
        get { rules.maxForwardTilt }
        set { objectWillChange.send(); if deskMode == .standing { standingForwardTiltThreshold = newValue } else { forwardTiltThreshold = newValue } }
    }
    var maxSideTilt: Double {
        get { rules.maxSideTilt }
        set { objectWillChange.send(); if deskMode == .standing { standingSideTiltThreshold = newValue } else { sideTiltThreshold = newValue } }
    }
    var maxShiftCM: Double {
        get { rules.maxShiftCM }
        set { objectWillChange.send(); if deskMode == .standing { standingShiftThresholdCM = newValue } else { shiftThresholdCM = newValue } }
    }

    private func apply(_ cal: HeadCalibration, keepPosition: Bool = false) {
        var next = PostureEstimator(calibration: cal)
        if keepPosition, let old = estimator { next.carryOverPosition(from: old) }
        estimator = next
        compensator.lever = cal.leverArm
    }

    // MARK: Calibration

    func calibrate() {
        guard airPodsStreaming else { calibrationError = "Put your AirPods in first."; return }
        Notifier.requestPermission()      // ask when it's relevant, not on first launch
        calibrationError = nil
        calibrationHint = nil
        calibrationRun += 1
        session = CalibrationSession(slouchTest: slouchTestOnCalibrate, earbud: activeEarbud, deskMode: deskMode)
        state = .calibrating
        begin(run: calibrationRun)
    }

    /// Shows the session's current step and starts its clock.
    private func begin(run: Int) {
        guard let s = session else { return }
        compensator.lever = s.compensatorLever
        calibrationPrompt = s.prompt
        calibrationStep = s.progress
        let index = s.index
        DispatchQueue.main.asyncAfter(deadline: .now() + s.step.seconds) { [weak self] in
            guard let self, self.calibrationRun == run, self.session?.index == index else { return }
            self.advance(run: run)
        }
    }

    private func advance(run: Int) {
        guard var s = session else { return }
        let result = s.advance()
        session = s
        switch result {
        case .next: begin(run: run)
        case .finished: finishCalibration()
        case .failed(let f): failCalibration(f.message(deskMode: deskMode))
        }
    }

    private func record(_ k: HeadKinematics) {
        guard var s = session else { return }
        let doneEarly = s.record(k)
        session = s
        if doneEarly { advance(run: calibrationRun) }
    }

    private func finishCalibration() {
        guard let s = session else { return }
        session = nil
        calibrationPrompt = nil
        calibrationStep = nil
        switch s.finish(currentTiltLimit: maxForwardTilt, currentShiftCM: maxShiftCM) {
        case .success(let done):
            if let o = done.slouchTest {
                Self.log.notice("Slouch test: tilt \(o.slouchTiltDegrees, format: .fixed(precision: 1))°, shift \(o.slouchShiftCM, format: .fixed(precision: 1)) cm, neutral repeat \(o.neutralRepeatDegrees, format: .fixed(precision: 1))°")
            }
            if let t = done.forwardTilt { maxForwardTilt = t }
            if let c = done.shiftCM { maxShiftCM = c }
            done.calibration.save()
            apply(done.calibration)
            resetStreak()
            state = .good
            calibrationHint = done.notes.isEmpty ? nil : "Calibrated. " + done.notes.joined(separator: " ")
        case .failure(let f):
            failCalibration(f.message(deskMode: deskMode))
        }
    }

    private func failCalibration(_ message: String) {
        session = nil
        calibrationPrompt = nil
        calibrationStep = nil
        calibrationError = message
        if let cal = estimator?.calibration { compensator.lever = cal.leverArm }
        state = estimator == nil ? .needsCalibration : .good
    }

    /// Calibrations from older versions (two-step, no lever arm) still work until you recalibrate.
    private func migrateLegacyCalibration() {
        let d = UserDefaults.standard
        guard HeadCalibration.load(for: .unknown) == nil,
              let g = d.array(forKey: "neutralGravity") as? [Double], g.count == 3,
              let f = d.array(forKey: "forwardAxis") as? [Double], f.count == 3 else { return }
        let g0 = SIMD3(g[0], g[1], g[2])
        HeadCalibration(neutralGravity: g0, forward: SIMD3(f[0], f[1], f[2]),
                        leverArm: HeadCalibration.defaultLever(neutralGravity: g0), leverFitted: false).save()
        d.removeObject(forKey: "neutralGravity")
        d.removeObject(forKey: "forwardAxis")
    }

    func dismissHint() { calibrationHint = nil }

    func zeroRelativePosition() {
        positionTracker.zero()
        relativeUpCM = 0
        relativeHorizontalCM = 0
        relativeApproximate = false
    }

    // MARK: Pause

    func pause(minutes: Double) {
        pausedUntil = Date().addingTimeInterval(minutes * 60)
        resetStreak()
    }

    func resume() { pausedUntil = nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }

    // MARK: Core loop (1 Hz)

    private func tick() {
        let now = Date()
        rollStatsIfNewDay(now)
        if session != nil { clearLookDown(); return }

        if let until = pausedUntil {
            if now < until { state = .paused; clearLookDown(); return }
            pausedUntil = nil
        }
        guard airPodsStreaming else { state = .noAirPods; clearLookDown(); return }   // streak pauses, doesn't reset
        guard estimator != nil else { state = .needsCalibration; clearLookDown(); return }

        if deskMode == .standing { standingSecondsToday += 1 } else { sittingSecondsToday += 1 }
        hunch.deskMode = deskMode
        // Your personal model only takes over once it clearly beats chance on held-out answers.
        isHunched = hunch.add(reading, model: hunchLearner.classifier.flatMap { $0.isUsable ? $0 : nil })
        lookDown.graceSeconds = Int(lookDownGraceSeconds)
        let verdict = PostureTick.assess(reading, rules: rules, grace: &lookDown, hunched: isHunched)
        let reasons = verdict.reasons, signal = verdict.signal
        lookDownRemaining = verdict.lookDownRemaining
        lookingDownCounts = lookDown.hasRunOut
        // While you're sitting well and still, let the neutral pose follow small AirPod shifts (capped at 4°).
        if followAirPodShifts, reasons.isEmpty, !verdict.lookingDown, estimator?.isStill == true,
           let sg = smoothedGravity {
            estimator?.adaptNeutral(toward: sg, dt: 1)
        }
        neutralDriftDegrees = estimator?.neutralDriftDegrees ?? 0
        slouchReasons = reasons
        maybeAskCheckIn(now)

        // Looking down within its grace is neither: it isn't sitting well, and it doesn't count as slouching yet.
        switch signal {
        case .good: goodSecondsToday += 1
        case .slouching: badSecondsToday += 1
        case .holding: break
        }
        // Looking down, still within its grace: the ding and the slouch clock wait (it isn't recovery).
        var alert = false
        if signal == .holding {
            dingRule.hold()
        } else {
            // A gentle ding a few seconds after a slouch is detected (not every time you brush past the limit).
            dingRule.holdSeconds = Int(dingDelaySeconds)
            if dingRule.tick(slouching: signal == .slouching, now: now), dingOnSlouch {
                Chime.playGentle()
                Self.log.notice("Slouch ding (\(Int(self.dingDelaySeconds)) s after detection)")
            }
            slouchTimer.alertSeconds = alertSeconds
            slouchTimer.recoverySeconds = Int(recoverySeconds)
            alert = slouchTimer.tick(slouching: signal == .slouching)
        }
        slouchSeconds = slouchTimer.slouchSeconds
        recoveryProgress = signal == .holding ? nil : slouchTimer.recoveryProgress   // paused, not counting down
        // Status reflects your posture *right now*; the slouch timer keeps its own (forgiving) clock.
        state = reasons.isEmpty ? .good : .slouching

        if alert {
            alertCount += 1
            let why = reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))"
            let spoke = chimeOnAlert && Chime.playAlert()     // no voice: the notification makes its sound instead
            Notifier.send(title: "Check your posture",
                          body: "You've been slouching for about \(slouchSeconds / 60) minutes\(why). Sit tall, chin back, shoulders down.",
                          sound: !spoke)
        }
    }

    // MARK: Hunch learning

    /// When you tap, you've usually already started sitting up, so a tap describes the moment
    /// a few seconds earlier.
    static let tapLead = 5

    /// "I'm hunched" / "I'm fine": labels the moment just before the tap (with its head history).
    func labelHunch(_ hunched: Bool) {
        let trace = hunch.trace()
        guard trace.count >= HunchFeatureSet.window + Self.tapLead else {
            showFeedback("Not saved: needs 30 s of tracking first", ok: false)
            return
        }
        let replaced = record(trace: trace, lead: Self.tapLead, hunched: hunched)
        confirm(hunched, replaced: replaced)
    }

    func forgetHunchAnswers() {
        hunchLearner.forgetAll()
        trainingGeneration += 1
        hunchSummary = hunchLearner.summary
        hunchReport = hunchLearner.report
        hunchFeedback = nil
    }

    /// Retrains the hunch model in the background (comparing models takes a moment with hundreds of
    /// answers), then swaps it in. A newer answer cancels an older, still-running retrain.
    private func retrainHunchModel() {
        trainingGeneration += 1
        let generation = trainingGeneration
        let examples = hunchLearner.examples
        hunchReport.training = true
        Task.detached(priority: .utility) {
            let classifier = HunchTrainer.train(examples)
            await MainActor.run { [weak self] in
                guard let self, generation == self.trainingGeneration else { return }
                self.hunchLearner.setClassifier(classifier)
                self.hunchSummary = self.hunchLearner.summary
                self.hunchReport = self.hunchLearner.report
            }
        }
    }

    private func confirm(_ hunched: Bool, replaced: Bool = false) {
        let n = hunchLearner.examples.count
        showFeedback(replaced
                     ? "✓ Updated your last answer to \(hunched ? "hunched" : "fine")"
                     : "✓ Recorded as \(hunched ? "hunched" : "fine") · \(n) answer\(n == 1 ? "" : "s")", ok: true)
    }

    private func showFeedback(_ text: String, ok: Bool) {
        hunchFeedback = (text, ok)
        feedbackClear?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hunchFeedback = nil }
        feedbackClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }

    @discardableResult
    private func record(trace: [PostureReading], lead: Int, hunched: Bool) -> Bool {
        let replaced = hunchLearner.add(trace: trace, lead: lead, hunched: hunched, deskMode: deskMode)
        defer { retrainHunchModel() }
        hunchSummary = hunchLearner.summary
        hunchReport = hunchLearner.report
        return replaced
    }

    /// Asks "are you hunched?" now and then, at the moments where the answer teaches the most
    /// (the model is unsure or the rules think you might be). Stops once the model is confident.
    private func maybeAskCheckIn(_ now: Date) {
        guard hunchCheckIns, !(hunchLearner.classifier?.isConfident ?? false),
              now.timeIntervalSince(lastCheckIn) >= Self.checkInInterval,
              hunch.isUncertain, hunch.features() != nil else { return }
        lastCheckIn = now
        pendingCheckIn = (hunch.trace(), now)
        Notifier.sendCheckIn()
    }

    private func answerCheckIn(_ hunched: Bool) {
        // Use what the head was doing when we asked, if the answer came reasonably soon.
        // A check-in describes the moment it was asked (lead 0): you hadn't reacted yet.
        if let p = pendingCheckIn, Date().timeIntervalSince(p.asked) < 10 * 60, p.trace.count >= HunchFeatureSet.window {
            record(trace: p.trace, lead: 0, hunched: hunched)
        } else if hunch.trace().count >= HunchFeatureSet.window + Self.tapLead {
            record(trace: hunch.trace(), lead: Self.tapLead, hunched: hunched)
        } else {
            pendingCheckIn = nil
            showFeedback("Not saved: tracking wasn't running", ok: false)
            notchFlashCount += 1
            return
        }
        pendingCheckIn = nil
        confirm(hunched)
        notchFlashCount += 1          // pop the notch open so you can see it was recorded
    }

    /// Not tracking right now (calibrating, paused, no AirPods…): no looking-down episode is running.
    private func clearLookDown() {
        lookDown.reset()
        if lookDownRemaining != nil { lookDownRemaining = nil }
        if lookingDownCounts { lookingDownCounts = false }
    }

    /// Which readings to highlight: body reasons always, looking-down ones once their grace has run out.
    /// `lookingDownCounts` comes from the grace itself, so the start of a glance (before the next tick
    /// notices it) isn't flagged.
    var readingFlags: (tilt: Bool, head: Bool) {
        rules.flags(for: reading, lookingDownCounts: lookingDownCounts)
    }

    private func resetStreak() {
        slouchTimer.reset()
        lookDown.reset()
        lookDownRemaining = nil
        lookingDownCounts = false
        slouchSeconds = 0
        recoveryProgress = nil
    }

    private func rollStatsIfNewDay(_ now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if day != statsDay {
            statsDay = day
            goodSecondsToday = 0
            badSecondsToday = 0
            sittingSecondsToday = 0
            standingSecondsToday = 0
        }
    }

    /// Sends a check-in right away (for trying it out).
    func sendCheckInNow() {
        Notifier.requestPermission()
        pendingCheckIn = hunch.features() != nil ? (hunch.trace(), Date()) : nil
        lastCheckIn = Date()
        Notifier.sendCheckIn()
    }

    #if DEBUG
    /// Debug-only: put the monitor in a realistic "tracking" state for layout snapshots.
    func debugPreview(slouching: Bool) {
        let g0 = SIMD3<Double>(0, 0, -1)
        estimator = PostureEstimator(calibration: HeadCalibration(neutralGravity: g0, forward: SIMD3(0, 1, 0),
                                                                  leverArm: .zero, leverFitted: false))
        reading = PostureReading(tilt: 18, pitch: slouching ? 18 : 6, roll: 3, forwardCM: slouching ? 6.2 : 1.1,
                                 dropCM: 0.8, forwardSigmaCM: 0.4, dropSigmaCM: 0.3,
                                 forwardMoveCM: slouching ? 5.5 : 0, dropMoveCM: 0.2)
        state = slouching ? .slouching : .good
        slouchSeconds = slouching ? 372 : 0
        relativeUpCM = 2
        relativeHorizontalCM = 4
        showFeedback("✓ Recorded as hunched · 13 answers", ok: true)
        hunchReport = HunchReport(hunchedAnswers: 14, fineAnswers: 17, personalized: true, confident: false,
                                  evaluation: HunchEvaluation(accuracy: 0.84, catchRate: 0.79, falseAlarmRate: 0.12, tested: 31),
                                  recentAgreement: (9, 11), signals: ["chin-poke pattern", "head further forward", "holding very still"])
        sittingSecondsToday = 3 * 3600 + 610
        standingSecondsToday = 47 * 60
    }
    #endif

    func sendTestNotification() {
        Notifier.requestPermission()
        Notifier.send(title: "Posture", body: "Notifications are working 👍")
        alertCount += 1
    }
}

