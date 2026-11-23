import AppKit
import SwiftUI

/// A small window showing how well the hunch model is doing and what it has learned.
@MainActor
enum HunchModelWindow {
    private static var window: NSWindow?

    static func show(_ monitor: PostureMonitor) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Hunch Model"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HunchModelView().environmentObject(monitor))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HunchModelView: View {
    @EnvironmentObject var m: PostureMonitor

    private var r: HunchReport { m.hunchReport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                status
                answers
                model
                accuracy
                learned
                checkIns
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    // MARK: Sections

    private var status: some View {
        HStack(spacing: 12) {
            Image(systemName: r.personalized ? "brain.head.profile" : "ruler")
                .font(.system(size: 28)).foregroundStyle(r.personalized ? .green : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.personalized ? (r.confident ? "Personalized and confident" : "Personalized, still learning")
                                    : (r.modelKind != nil ? "Built-in rules (your model isn't reliable yet)" : "Using built-in rules")).font(.headline)
                Text(r.personalized
                     ? "Hunch detection uses a model trained on your own answers, falling back to the rules when it's unsure."
                     : "Hunch detection uses general rules until you've given enough answers to train your own model.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var answers: some View {
        section("Your answers") {
            HStack(spacing: 16) {
                countBox("Hunched", r.hunchedAnswers, of: HunchModel.minPerClass, color: .orange)
                countBox("Fine", r.fineAnswers, of: HunchModel.minPerClass, color: .green)
                countBox("Total", r.hunchedAnswers + r.fineAnswers, of: HunchModel.minExamples, color: .blue)
            }
            let total = r.hunchedAnswers + r.fineAnswers
            if total > 0 {
                Label("\(r.distinctMoments) distinct moment\(r.distinctMoments == 1 ? "" : "s") (answers under 20 s apart describe the same moment and count once)",
                      systemImage: "clock")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                if r.distinctMoments < 40 {
                    Label("For a better model, spread answers out: different times of day, different sessions, both when hunched and when sitting well. One tap per moment is enough.",
                          systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("A model is trained once you have \(HunchModel.minExamples) answers with at least \(HunchModel.minPerClass) of each. "
                 + "Answer both ways: \"fine\" answers matter as much as \"hunched\" ones. Tapping again within 10 s replaces your last answer.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("I'm hunched") { m.labelHunch(true) }.tint(.orange)
                Button("I'm fine") { m.labelHunch(false) }.tint(.green)
                if let fb = m.hunchFeedback {
                    Text(fb.text).font(.caption.weight(.semibold)).foregroundStyle(fb.ok ? .green : .orange)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var model: some View {
        section("Model") {
            if let kind = r.modelKind {
                HStack {
                    Label(kind.label, systemImage: kind == .boostedTrees ? "tree" : "function")
                        .font(.callout.weight(.semibold))
                    if r.training { ProgressView().controlSize(.small); Text("retraining…").font(.caption).foregroundStyle(.secondary) }
                }
                Text(kind == .boostedTrees
                     ? "Many small decision trees, each asking a few yes/no questions about your head (\"chin up?\", \"head more than 3 cm forward?\"), added together. It learns combinations and thresholds."
                     : "A weighted sum of your head signals. Simple and dependable with fewer answers, but it can only learn \"more of X means more likely hunched\".")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let lr = r.logisticScore {
                    VStack(alignment: .leading, spacing: 4) {
                        scoreRow("Logistic regression", lr, chosen: kind == .logistic)
                        if let bt = r.treesScore {
                            scoreRow("Gradient-boosted trees", bt, chosen: kind == .boostedTrees)
                        } else {
                            Text("Trees are tried once you have 40 answers.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Both are scored on answers from time periods they didn't train on; the better one is used.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let why = r.notUsedReason {
                    Label("Not used yet: \(why)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let t = r.threshold {
                    Text("Calls \"hunched\" above \(Int((t * 100).rounded()))% likelihood (tuned to balance catches and false alarms).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if r.training {
                HStack { ProgressView().controlSize(.small); Text("Training…").font(.callout) }
            } else {
                Text("No personal model yet.").font(.callout).foregroundStyle(.secondary)
            }
            let total = r.hunchedAnswers + r.fineAnswers
            if total > 0 {
                Text("\(r.withHistory) of \(total) answers include the full head history (new answers do); older ones use the basic 30-second summary.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scoreRow(_ name: String, _ score: Double, chosen: Bool) -> some View {
        HStack {
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? .green : .secondary)
            Text(name)
            Spacer()
            Text("\(Int((score * 100).rounded()))%").monospacedDigit().bold()
        }
        .font(.callout)
    }

    private var accuracy: some View {
        section("How well it works") {
            if let e = r.evaluation {
                HStack(spacing: 16) {
                    percentBox("Balanced accuracy", e.balancedAccuracy, good: e.balancedAccuracy >= 0.8)
                    percentBox("Catches hunches", e.catchRate, good: e.catchRate >= 0.8)
                    percentBox("False alarms", e.falseAlarmRate, good: e.falseAlarmRate <= 0.2, lowerIsBetter: true)
                }
                Text("Measured fairly: answers are grouped into 5 blocks of time, and each block is predicted by a model trained only on the others (\(e.tested) answers). Balanced accuracy weighs hunched and fine answers equally.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough answers yet to measure accuracy.").font(.callout).foregroundStyle(.secondary)
            }
            if let a = r.recentAgreement {
                Label("Agreed with you \(a.agreed) of the last \(a.total) times, before you answered",
                      systemImage: "checkmark.bubble")
                    .font(.callout)
            }
        }
    }

    private var learned: some View {
        section("What your hunch looks like") {
            if r.signals.isEmpty {
                Text("Built-in rules: head forward or lower with the chin level or up, held for a minute; or the chin slowly drifting up over several minutes. Looking down at the keyboard doesn't count.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The signals your model relies on most:").font(.callout)
                ForEach(Array(r.signals.enumerated()), id: \.offset) { i, s in
                    Label(s.prefix(1).uppercased() + s.dropFirst(), systemImage: "\(i + 1).circle.fill")
                }
            }
        }
    }

    private var checkIns: some View {
        section("Check-ins") {
            Toggle("Ask me \"am I hunched?\" now and then", isOn: $m.hunchCheckIns)
            Text(r.confident
                 ? "Your model is confident (40+ answers, 85%+ match), so check-ins have stopped."
                 : "At most every 20 minutes, only at moments where your answer teaches the model the most. They stop once it's confident.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Ask me now") { m.sendCheckInNow() }
                Text("Sends the check-in notification right away. Answer Yes or No on it; it records the last 30 s, just like the buttons above.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Forget all my answers…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Forget all hunch answers?"
                alert.informativeText = "Your personal model will be deleted and hunch detection goes back to the built-in rules."
                alert.addButton(withTitle: "Forget")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { m.forgetHunchAnswers() }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func countBox(_ label: String, _ value: Int, of target: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(min(value, target)), total: Double(target)).tint(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentBox(_ label: String, _ value: Double, good: Bool, lowerIsBetter: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int((value * 100).rounded()))%").font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(good ? .green : .orange)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
