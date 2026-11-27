import Foundation

/// Sitting or standing (for standing desks).
enum DeskMode: String, Codable, CaseIterable, Identifiable {
    case sitting, standing
    var id: String { rawValue }
    var label: String { self == .sitting ? "Sitting" : "Standing" }
    var symbol: String { self == .sitting ? "chair" : "figure.stand" }
}

/// Detects when you stand up or sit down from how far your head has risen or dropped.
///
/// Fed by its own display-independent position tracker (pressing Zero on the "Moved" readout doesn't
/// affect it). Standing up raises your head roughly 40–60 cm, so a settled rise of more than 30 cm
/// since the last change means you stood up, and a matching drop means you sat down. It only decides
/// once the movement has settled. You can always correct it by hand.
struct DeskModeDetector {
    private(set) var mode: DeskMode = .sitting
    private var baseline = 0.0               // tracker height (m) at the last change
    static let threshold = 0.30

    /// - Returns: true when the mode changed.
    mutating func update(heightCM: Double, moving: Bool) -> Bool {
        guard !moving else { return false }
        let h = heightCM / 100
        let delta = h - baseline
        if mode == .sitting, delta > Self.threshold {
            mode = .standing; baseline = h; return true
        }
        if mode == .standing, delta < -Self.threshold {
            mode = .sitting; baseline = h; return true
        }
        // Small settled shifts (leaning, shuffling, tracker drift) move the reference with you,
        // so they can't add up to a false "stood up" over a long session.
        if abs(delta) < 0.12 { baseline += 0.05 * delta }
        return false
    }

    /// Manual correction from the UI.
    mutating func set(_ m: DeskMode, heightCM: Double) {
        mode = m
        baseline = heightCM / 100
    }
}
