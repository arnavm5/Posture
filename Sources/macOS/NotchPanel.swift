import AppKit
import SwiftUI

/// Live posture "island" that wraps around the MacBook notch / camera housing.
/// Collapsed: status + timer on either side of the notch. Hover (or an alert): drops open
/// with the live 3D mannequin and your numbers.
@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var alerting = false

    static let wing: CGFloat = 52
    static let expandedSize = CGSize(width: 390, height: 285)
    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * Self.wing, height: notchHeight) }
}

@MainActor
final class NotchController {
    private let panel: NSPanel
    private let model = NotchModel()
    private let monitor: PostureMonitor
    private var timer: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var forcedUntil: Date?
    private var lastAlertCount = 0
    private var lastFlashCount = 0
    private static let panelSize = NSSize(width: 430, height: 315)

    init(monitor: PostureMonitor) {
        self.monitor = monitor
        lastAlertCount = monitor.alertCount
        lastFlashCount = monitor.notchFlashCount
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: NotchView(model: model, panelSize: Self.panelSize).environmentObject(monitor))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host

        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let s = screen else { return }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.notchWidth = s.frame.width - l.width - r.width
            model.notchHeight = s.safeAreaInsets.top
        } else {
            // No notch: sit in the middle of the menu bar like a small island.
            model.notchWidth = 120
            model.notchHeight = max(24, s.frame.maxY - s.visibleFrame.maxY)
        }
        panel.setFrame(NSRect(x: s.frame.midX - Self.panelSize.width / 2, y: s.frame.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
    }

    /// The black shape's current rect in screen coordinates.
    private func shapeRect(expanded: Bool) -> NSRect {
        guard let s = screen else { return .zero }
        let size = expanded ? NotchModel.expandedSize : model.collapsedSize
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func poll() {
        if !monitor.showInNotch {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }

        let now = Date()
        if monitor.alertCount != lastAlertCount {
            lastAlertCount = monitor.alertCount
            forcedUntil = now.addingTimeInterval(6)
        }
        if monitor.notchFlashCount != lastFlashCount {      // show "recorded" feedback briefly
            lastFlashCount = monitor.notchFlashCount
            forcedUntil = max(forcedUntil ?? now, now.addingTimeInterval(3.5))
        }
        let forced = forcedUntil.map { now < $0 } ?? false

        let hot = shapeRect(expanded: model.expanded).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if hot { leftSince = nil; hoverSince = hoverSince ?? now } else { hoverSince = nil; leftSince = leftSince ?? now }

        let hoverOpen = hoverSince.map { now.timeIntervalSince($0) > 0.15 } ?? false
        let lingering = model.expanded && (leftSince.map { now.timeIntervalSince($0) < 0.4 } ?? true)
        let target = forced || hoverOpen || lingering

        if target != model.expanded {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { model.expanded = target }
        }
        if forced != model.alerting { model.alerting = forced }
        panel.ignoresMouseEvents = !model.expanded
    }
}

// MARK: - Views

private struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        // Square top (flush with the screen edge) with a small outward flare, rounded bottom.
        let flare = min(8, radius)
        var p = Path()
        p.move(to: CGPoint(x: r.minX - flare, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX + flare, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + flare), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + flare))
        p.addQuadCurve(to: CGPoint(x: r.minX - flare, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let panelSize: NSSize
    @EnvironmentObject var m: PostureMonitor

    var body: some View {
        let size = model.expanded ? NotchModel.expandedSize : model.collapsedSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.expanded ? 26 : 12)
                    .fill(.black)
                    .shadow(color: model.alerting ? .orange.opacity(0.8) : .black.opacity(model.expanded ? 0.4 : 0),
                            radius: model.alerting ? 14 : 10)
                VStack(spacing: 0) {
                    topRow.frame(height: model.notchHeight)
                    if model.expanded {
                        expanded
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    }
                }
                // Pin to the top: if content ever outgrows the panel it's cut off at the bottom,
                // never pushed up under the notch.
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                if !model.expanded && m.slouchSeconds > 0 { progressLine(width: size.width) }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // Collapsed wings either side of the notch.
    private var topRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                LiveDot(color: m.state.color, pulsing: m.state == .slouching || model.alerting)
                Image(systemName: m.state.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(m.state.color)
            }
            .frame(width: NotchModel.wing, alignment: .center)
            Spacer(minLength: model.notchWidth)
            rightWing.frame(width: NotchModel.wing, alignment: .center)
        }
        .padding(.horizontal, model.expanded ? 12 : 0)
    }

    @ViewBuilder private var rightWing: some View {
        switch m.state {
        case .slouching:
            Text(clock(m.slouchSeconds)).foregroundStyle(.orange)
        case .good:
            if let p = m.recoveryProgress {
                Text("\(Int((1 - p) * m.recoverySeconds))s").foregroundStyle(.green)
            } else {
                Text("\(Int(max(m.reading.pitch, abs(m.reading.roll))))°").foregroundStyle(.green)
            }
        case .calibrating:
            ProgressView().controlSize(.mini)
        case .paused:
            Image(systemName: "pause.fill").foregroundStyle(.secondary)
        default:
            Image(systemName: "airpods").foregroundStyle(.secondary)
        }
    }

    private func progressLine(width: CGFloat) -> some View {
        let frac = min(1, CGFloat(m.slouchSeconds) / CGFloat(max(1, m.alertSeconds)))
        return VStack {
            Spacer()
            Capsule().fill(m.recoveryProgress == nil ? Color.orange : Color.green)
                .frame(width: max(4, (width - 28) * frac), height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        }
    }

    private var expanded: some View {
        HStack(alignment: .top, spacing: 10) {
            HeadView(headScene: m.headScene)
                .frame(width: 150, height: 220)
            VStack(alignment: .leading, spacing: 7) {
                Text(m.calibrationPrompt ?? m.state.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(m.state.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let step = m.calibrationStep {
                    Text("Step \(step.index) of \(step.of)").font(.caption2).foregroundStyle(.secondary)
                }
                if m.state == .good || m.state == .slouching {
                    metric("Tilt", String(format: "%d° fwd · %d° side", Int(m.reading.pitch), Int(abs(m.reading.roll))),
                           bad: m.reading.pitch > m.maxForwardTilt || abs(m.reading.roll) > m.maxSideTilt)
                    metric("Head", String(format: "%+.1f fwd · %+.1f low cm", m.reading.forwardCM, m.reading.dropCM),
                           bad: m.reading.forwardCM > m.maxShiftCM || m.reading.dropCM > m.maxShiftCM)
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: Double(min(m.slouchSeconds, m.alertSeconds)), total: Double(m.alertSeconds))
                            .tint(.orange)
                        Text(m.recoveryProgress.map { "Good! Timer resets in \(Int((1 - $0) * m.recoverySeconds))s" }
                             ?? (m.slouchSeconds > 0 ? "Slouching \(clock(m.slouchSeconds)) of \(clock(m.alertSeconds))" : "Nice — keep it up"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    positionLine
                    deskLine
                }
                // Shown in every state: a failed recalibration leaves you in "good" with the old calibration.
                if let err = m.calibrationError {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if m.isCalibrated { shouldersRow }
                HStack(spacing: 8) {
                    Button(m.isCalibrated ? "Recalibrate" : "Calibrate") { m.calibrate() }
                        .disabled(m.state == .calibrating)
                    if m.pausedUntil != nil {
                        Button("Resume") { m.resume() }
                    } else {
                        Button("Pause 1h") { m.pause(minutes: 60) }
                    }
                }
                .buttonStyle(NotchButtonStyle())
            }
            .foregroundStyle(.white)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var positionLine: some View {
        HStack(spacing: 6) {
            Text(String(format: "Moved %@↑ %+.0f  ↔ %.0f cm", m.relativeApproximate ? "≈ " : "",
                        m.relativeUpCM, m.relativeHorizontalCM))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Zero") { m.zeroRelativePosition() }.buttonStyle(NotchButtonStyle(compact: true))
        }
        .font(.system(size: 11))
    }

    /// Sitting vs standing today (standing desk), with the current position highlighted.
    private var deskLine: some View {
        HStack(spacing: 10) {
            ForEach(DeskMode.allCases) { mode in
                Label(dur(mode == .sitting ? m.sittingSecondsToday : m.standingSecondsToday), systemImage: mode.symbol)
                    .foregroundStyle(m.deskMode == mode ? .white : .secondary)
            }
            Spacer()
            Text(m.deskMode.label).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }

    /// Shorter wording for the narrow notch: "✓ Recorded as hunched · 13 answers" → "✓ Saved: hunched (13)".
    static func compact(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "Recorded as ", with: "Saved: ")
            .replacingOccurrences(of: "Updated your last answer to ", with: "Updated: ")
            .replacingOccurrences(of: "Not saved: needs 30 s of tracking first", with: "Not saved: need 30 s of tracking")
        if let r = t.range(of: " · ") {
            let count = t[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            t = String(t[..<r.lowerBound]) + " (\(count))"
        }
        return t
    }

    private func dur(_ s: Int) -> String { s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 60)m" }

    /// Teach the hunch detector, with a clear confirmation once an answer is recorded.
    private var shouldersRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 12)).foregroundStyle(m.isHunched ? .orange : .secondary)
                    .help(m.isHunched ? "Shoulders look hunched" : "Shoulders: tell it how you're sitting")
                Button("Hunched") { m.labelHunch(true) }.buttonStyle(NotchButtonStyle(tint: .orange))
                Button("Fine") { m.labelHunch(false) }.buttonStyle(NotchButtonStyle(tint: .green))
            }
            if let fb = m.hunchFeedback {
                Text(Self.compact(fb.text))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(fb.ok ? .green : .orange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: m.hunchFeedback?.text)
    }

    private func metric(_ name: String, _ value: String, bad: Bool) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(bad ? .orange : .white)
        }
        .font(.system(size: 12))
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

private struct LiveDot: View {
    var color: Color
    var pulsing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pulsing)) { ctx in
            let t = pulsing ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 1
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(color, lineWidth: 1.5).scaleEffect(1 + 1.4 * t).opacity(0.9 * (1 - t)))
        }
    }
}

/// Pill-shaped button for the dark notch panel: clearly a button, with a visible press state.
struct NotchButtonStyle: ButtonStyle {
    var tint: Color = .white
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NotchButton(configuration: configuration, tint: tint, compact: compact)
    }

    private struct NotchButton: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 8 : 11)
                .padding(.vertical, compact ? 3 : 5)
                .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.38 : 0.18)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.75))
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}
