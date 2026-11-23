import Foundation
import simd

/// Which earbud the motion data comes from. Each earbud sits differently, so each gets its own calibration.
enum Earbud: String, Codable {
    case unknown, left, right
}

/// Everything the app knows about how *your* AirPods sit on *your* head.
///
/// Built from a four-step calibration:
///  1. sit tall, looking at the screen  → neutral gravity (the "up" axis)
///  2. look down at the keyboard and back → the head's forward axis
///  3. turn left and right               ┐ rotations about different axes, used to fit the
///  4. tilt each ear toward the shoulder ┘ lever arm (earbud ↔ neck pivot) for swing compensation
struct HeadCalibration: Codable, Equatable {
    var neutralGravity: SIMD3<Double>
    var forward: SIMD3<Double>
    var leverArm: SIMD3<Double>
    var leverFitted: Bool
    var earbud: Earbud = .unknown
    /// Sitting or standing when this calibration was made (nil in older saves = sitting).
    var deskMode: DeskMode? = nil

    /// Head axes in the AirPods' frame.
    var up: SIMD3<Double> { -simd_normalize(neutralGravity) }
    var left: SIMD3<Double> { simd_normalize(simd_cross(up, forward)) }

    /// Default lever arm when it can't be fitted: earbud ≈ 9 cm above the neck pivot.
    static func defaultLever(neutralGravity g0: SIMD3<Double>) -> SIMD3<Double> { -simd_normalize(g0) * 0.09 }

    enum Failure: Error, Equatable {
        case noSignal
        case didNotLookDown
    }

    /// Solves the calibration from the recorded steps.
    static func solve(neutral: [SIMD3<Double>], lookDown: [SIMD3<Double>], leverFit: LeverArmFit,
                      earbud: Earbud, deskMode: DeskMode = .sitting) -> Result<HeadCalibration, Failure> {
        guard !neutral.isEmpty else { return .failure(.noSignal) }
        let g0 = simd_normalize(neutral.reduce(.zero, +) / Double(neutral.count))
        let down = lookDown.map(simd_normalize)
        // Looking down moves gravity toward the head's forward axis; use the furthest point reached.
        guard let g1 = down.max(by: { simd_dot($0, g0) > simd_dot($1, g0) }),
              acos(min(1, simd_dot(g1, g0))) > 10 * .pi / 180 else { return .failure(.didNotLookDown) }
        let f = simd_normalize(g1 - simd_dot(g1, g0) * g0)

        let prior = defaultLever(neutralGravity: g0)
        let fit = leverFit.solve(prior: prior)
        return .success(HeadCalibration(neutralGravity: g0, forward: f, leverArm: fit?.lever ?? prior,
                                        leverFitted: fit != nil, earbud: earbud, deskMode: deskMode))
    }

    // MARK: Persistence (one calibration per earbud, and per sitting / standing)

    /// The best saved calibration for this earbud and position, falling back to: this earbud sitting,
    /// then calibrations made when the earbud couldn't be identified (and older versions' calibrations).
    static func best(for earbud: Earbud, mode: DeskMode) -> HeadCalibration? {
        var order: [(Earbud, DeskMode)] = [(earbud, mode), (earbud, .sitting)]
        if earbud != .unknown { order += [(.unknown, mode), (.unknown, .sitting)] }
        for (e, m) in order { if let c = load(for: e, mode: m) { return c } }
        return nil
    }

    static func key(_ e: Earbud, _ mode: DeskMode = .sitting) -> String {
        "calibration.\(e.rawValue)" + (mode == .standing ? ".standing" : "")
    }

    static func load(for earbud: Earbud, mode: DeskMode = .sitting) -> HeadCalibration? {
        guard let data = UserDefaults.standard.data(forKey: key(earbud, mode)) else { return nil }
        return try? JSONDecoder().decode(HeadCalibration.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(earbud, deskMode ?? .sitting))
        }
    }
}
