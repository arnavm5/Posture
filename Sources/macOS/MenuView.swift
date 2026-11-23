import AppKit
import SwiftUI

/// Menu-bar popover: status pinned on top, everything else in a scrolling list of compact sections
/// (the less-used ones collapsed), and Pause / Quit pinned at the bottom.
struct MenuView: View {
    @EnvironmentObject var m: PostureMonitor

    // Which sections are open (remembered between launches).
    @AppStorage("menu.calibrationOpen") private var calibrationOpen = false
    @AppStorage("menu.limitsOpen") private var limitsOpen = false
    @AppStorage("menu.alertsOpen") private var alertsOpen = false
    @AppStorage("menu.generalOpen") private var generalOpen = false

    static let maxScrollHeight: CGFloat = 430
    /// Measured height of the scrolling content. Menu-bar popovers size themselves from the view's ideal
    /// height, and a ScrollView without an explicit height can report ~0 there (an empty menu), so the
    /// scroll area gets the content's real height, capped.
    @StateObject private var layout = MenuLayout()

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    now
                    if m.isCalibrated { shoulders }
                    section("Calibration & position", "scope", isOpen: $calibrationOpen) { calibration }
                    section("Slouch limits (\(m.deskMode.label.lowercased()))", "slider.horizontal.3", isOpen: $limitsOpen) { limits }
                    section("Alerts & sounds", "bell", isOpen: $alertsOpen) { alerts }
                    section("General", "gearshape", isOpen: $generalOpen) { general }
                }
                .padding(14)
                .background(GeometryReader { g in
                    Color.clear.preference(key: MenuContentHeight.self, value: g.size.height)
                })
            }
            .frame(height: min(layout.contentHeight, Self.maxScrollHeight))
            .onPreferenceChange(MenuContentHeight.self) { h in
                if h > 0, abs(h - layout.contentHeight) > 0.5 { layout.contentHeight = h }
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 330)
    }

    // MARK: Pinned top

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: m.state.symbol)
                .font(.title2)
                .foregroundStyle(m.state.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.calibrationPrompt ?? m.state.label).font(.headline)
                if let step = m.calibrationStep {
                    Text("Step \(step.index) of \(step.of)").font(.caption).foregroundStyle(.secondary)
                }
                if let p = m.recoveryProgress {
                    Text("Sitting well. Slouch timer resets in \(Int((1 - p) * m.recoverySeconds))s")
                        .font(.caption).foregroundStyle(.green)
                } else if m.slouchSeconds > 0 {
                    Text("Slouching for \(format(m.slouchSeconds)) · alert at \(Int(m.alertMinutes)) min")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let hint = m.calibrationHint {
                    HStack(alignment: .top, spacing: 4) {
                        Text(hint).font(.caption).foregroundStyle(.blue).fixedSize(horizontal: false, vertical: true)
                        Button { m.dismissHint() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                if let err = m.calibrationError {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !m.airPodsMotionSupported {
                    Text("Head tracking unavailable on this Mac.").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            if !m.isCalibrated {
                Button("Calibrate") { m.calibrate() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(m.state == .calibrating || !m.airPodsStreaming)
            }
        }
    }

    // MARK: Now (always visible)

    private var now: some View {
        let total = m.goodSecondsToday + m.badSecondsToday
        let pct = total > 0 ? Int(Double(m.goodSecondsToday) / Double(total) * 100) : 0
        return VStack(alignment: .leading, spacing: 5) {
            if m.state == .good || m.state == .slouching {
                row("Tilt", String(format: "%d° fwd · %d° %@", Int(m.reading.pitch), Int(abs(m.reading.roll)),
                                   m.reading.roll >= 0 ? "left" : "right"),
                    bad: m.reading.pitch > m.maxForwardTilt || abs(m.reading.roll) > m.maxSideTilt)
                row("Head (est.)", String(format: "%+.1f fwd · %+.1f low cm", m.reading.forwardCM, m.reading.dropCM),
                    bad: m.reading.forwardCM > m.maxShiftCM || m.reading.dropCM > m.maxShiftCM)
            }
            if m.airPodsStreaming {
                HStack {
                    Text("Moved").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%@↑ %+.0f  ↔ %.0f cm", m.relativeApproximate ? "≈ " : "",
                                m.relativeUpCM, m.relativeHorizontalCM)).monospacedDigit()
                    Button("Zero") { m.zeroRelativePosition() }.buttonStyle(.bordered).controlSize(.mini)
                }
                .help("Head movement since you pressed Zero (display only)")
            }
            HStack {
                Text("Today").foregroundStyle(.secondary)
                Spacer()
                Text("\(pct)% good").bold()
                Text("·").foregroundStyle(.secondary)
                Label(short(m.sittingSecondsToday), systemImage: DeskMode.sitting.symbol)
                    .foregroundStyle(m.deskMode == .sitting ? .primary : .secondary)
                Label(short(m.standingSecondsToday), systemImage: DeskMode.standing.symbol)
                    .foregroundStyle(m.deskMode == .standing ? .primary : .secondary)
            }
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Teach the hunch detector.
    private var shoulders: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(m.isHunched ? "Hunched" : "Shoulders", systemImage: "figure.walk.motion")
                    .foregroundStyle(m.isHunched ? .orange : .primary)
                Spacer()
                Button("I'm hunched") { m.labelHunch(true) }.buttonStyle(.bordered).tint(.orange)
                Button("I'm fine") { m.labelHunch(false) }.buttonStyle(.bordered).tint(.green)
            }
            .font(.caption)
            .controlSize(.small)
            HStack(alignment: .firstTextBaseline) {
                if let fb = m.hunchFeedback {
                    Text(fb.text).font(.caption.weight(.semibold)).foregroundStyle(fb.ok ? .green : .orange)
                } else {
                    Text(m.hunchSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button("Model…") { HunchModelWindow.show(m) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Collapsible sections

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { m.deskMode }, set: { m.setDeskMode($0) })) {
                ForEach(DeskMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption("Sitting or standing is detected automatically; tap to correct it.")
            Button(m.isCalibrated ? "Recalibrate (\(m.deskMode.label.lowercased()))" : "Calibrate") { m.calibrate() }
                .disabled(m.state == .calibrating)
            caption("About 15 s: sit or stand tall, look down and back up, turn left and right, tilt each ear to its shoulder. Sitting and standing each keep their own calibration.")
            Toggle("Follow small AirPod shifts", isOn: $m.followAirPodShifts)
            caption(m.followAirPodShifts
                    ? (m.neutralDriftDegrees >= 0.5
                       ? String(format: "Adjusted %.1f° so far (max 4°). Only while you're sitting well and still.", m.neutralDriftDegrees)
                       : "Your neutral pose slowly follows small shifts in how your AirPods sit (max 4°), only while you're sitting well.")
                    : "Off: your neutral pose stays exactly as calibrated.")
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("Forward tilt: \(Int(m.maxForwardTilt))°", value: $m.maxForwardTilt, in: 5...35, step: 1)
            Stepper("Side tilt: \(Int(m.maxSideTilt))°", value: $m.maxSideTilt, in: 5...35, step: 1)
            Stepper("Head shift: \(Int(m.maxShiftCM)) cm", value: $m.maxShiftCM, in: 2...15, step: 1)
            Stepper("Alert after: \(Int(m.alertMinutes)) min", value: $m.alertMinutes, in: 1...60, step: 1)
            caption("Tilt and shift limits apply to \(m.deskMode.label.lowercased()); sitting and standing have their own.")
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 6) {
            soundToggle("Ding when I start slouching", $m.dingOnSlouch) { Chime.playGentle() }
            Stepper(m.dingDelaySeconds < 1 ? "Ding: right away" : "Ding after: \(Int(m.dingDelaySeconds)) s of slouching",
                    value: $m.dingDelaySeconds, in: 0...30, step: 1)
                .disabled(!m.dingOnSlouch)
            soundToggle("Chime with the slouch alert", $m.chimeOnAlert) { Chime.playAlert() }
            Toggle("Ask \"am I hunched?\" now and then", isOn: $m.hunchCheckIns)
            HStack {
                Button("Test alert") { m.sendTestNotification() }
                Button("Ask me now") { m.sendCheckInNow() }
            }
            .controlSize(.small)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mannequin", selection: $m.style) {
                ForEach(MannequinStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show live status in the notch", isOn: $m.showInNotch)
            Toggle("Launch at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
        }
    }

    // MARK: Pinned bottom

    private var footer: some View {
        HStack {
            if m.pausedUntil != nil {
                Button("Resume") { m.resume() }
            } else {
                Button("Pause 1h") { m.pause(minutes: 60) }
            }
            Spacer()
            Label(m.airPodsStreaming ? "AirPods" : "No AirPods", systemImage: "airpods")
                .font(.caption).foregroundStyle(m.airPodsStreaming ? .secondary : .tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, _ icon: String, isOpen: Binding<Bool>,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isOpen) {
            content()
                .font(.callout)
                .padding(.top, 6)
                .padding(.leading, 2)
        } label: {
            Label(title, systemImage: icon).font(.callout.weight(.medium))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() } }
        }
    }

    private func soundToggle(_ title: String, _ isOn: Binding<Bool>, preview: @escaping () -> Void) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Button(action: preview) { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.borderless).help("Preview")
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ name: String, _ value: String, bad: Bool) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().bold().foregroundStyle(bad ? .orange : .primary)
        }
    }

    private func format(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 60)m \(s % 60)s"
    }

    private func short(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600)h\(s % 3600 / 60)m" : "\(s / 60)m"
    }
}

final class MenuLayout: ObservableObject {
    @Published var contentHeight: CGFloat = 260
}

private struct MenuContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
