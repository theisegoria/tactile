import Foundation
import Tactile

/// An editable adaptive-trigger design: one effect family plus its parameters.
/// The Trigger Designer and the Composer's trigger track share it. It builds a
/// validated `TriggerEffect` through the library's factories and derives a
/// resistance/vibration curve over trigger travel for display only (the
/// firmware's real force profile is not measured; see `curve`).
struct TriggerDesign: Codable, Hashable, Sendable {
    enum Family: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, feedback, weapon, vibration, slope, zoneFeedback, zoneVibration, bow, galloping, machine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .feedback: "Feedback"
            case .weapon: "Weapon"
            case .vibration: "Vibration"
            case .slope: "Slope"
            case .zoneFeedback: "Per-zone feedback"
            case .zoneVibration: "Per-zone vibration"
            case .bow: "Bow"
            case .galloping: "Galloping"
            case .machine: "Machine"
            }
        }
        /// Families the reference implementation marks unofficial.
        var isUnofficial: Bool { self == .bow || self == .galloping || self == .machine }
        var vibrates: Bool { self == .vibration || self == .zoneVibration || self == .galloping || self == .machine }
    }

    var family: Family = .feedback
    var start = 2
    var end = 6
    var strength = 5
    var secondStrength = 8
    var frequency = 30
    var period = 2
    var firstFoot = 2
    var secondFoot = 5
    var zones = [0, 0, 2, 3, 4, 5, 6, 6, 6, 6]

    static let off = TriggerDesign(family: .off)

    func effect() throws -> TriggerEffect {
        switch family {
        case .off: return .off
        case .feedback: return try .feedback(position: start, strength: strength)
        case .weapon: return try .weapon(start: start, end: end, strength: strength)
        case .vibration: return try .vibration(position: start, amplitude: strength, frequency: frequency)
        case .slope: return try .slopeFeedback(startPosition: start, endPosition: end, startStrength: strength, endStrength: secondStrength)
        case .zoneFeedback: return try .multiplePositionFeedback(strengths: zones)
        case .zoneVibration: return try .multiplePositionVibration(frequency: frequency, amplitudes: zones)
        case .bow: return try .bow(start: start, end: end, strength: strength, snapForce: secondStrength)
        case .galloping: return try .galloping(start: start, end: end, firstFoot: firstFoot, secondFoot: secondFoot, frequency: frequency)
        case .machine: return try .machine(start: start, end: end, amplitudeA: strength, amplitudeB: secondStrength, frequency: frequency, period: period)
        }
    }

    var validationMessage: String? {
        do { _ = try effect(); return nil } catch { return Self.describe(error) }
    }

    static func describe(_ error: any Error) -> String {
        if let v = error as? TriggerEffect.ValidationError { return String(describing: v) }
        return (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// One sample of the displayed curve. `travel` runs 0…1 over the trigger's
    /// pull; `force` and `vibration` are 0…1 of the parameter maximum.
    struct CurvePoint: Identifiable, Hashable, Sendable {
        var travel: Double
        var force: Double
        var vibration: Double
        var id: Double { travel }
    }

    /// The curve the parameters describe, over ten zones of travel. This is a
    /// reading of the parameters, not a measurement of the firmware's force.
    func curve(samples: Int = 101) -> [CurvePoint] {
        (0..<samples).map { i in
            let travel = Double(i) / Double(samples - 1)
            let zone = min(9.999, travel * 10)
            let (f, v) = level(atZone: zone)
            return CurvePoint(travel: travel, force: max(0, min(1, f)), vibration: max(0, min(1, v)))
        }
    }

    private func level(atZone z: Double) -> (Double, Double) {
        let s = Double(strength) / 8, s2 = Double(secondStrength) / 8
        let zs = Double(start), ze = Double(end)
        switch family {
        case .off:
            return (0, 0)
        case .feedback:
            return (z >= zs ? s : 0, 0)
        case .weapon:
            return (z >= zs && z < ze ? s : 0, 0)
        case .vibration:
            return (0, z >= zs && frequency > 0 ? s : 0)
        case .slope:
            guard z >= zs else { return (0, 0) }
            let a = Double(strength) / 8, b = Double(secondStrength) / 8
            let t = ze > zs ? min(1, (z - zs) / (ze - zs)) : 1
            return (a + (b - a) * t, 0)
        case .zoneFeedback:
            return (Double(zones[safe: Int(z)] ?? 0) / 8, 0)
        case .zoneVibration:
            return (0, frequency > 0 ? Double(zones[safe: Int(z)] ?? 0) / 8 : 0)
        case .bow:
            guard z >= zs, z < ze + 1 else { return (0, 0) }
            let t = ze > zs ? min(1, (z - zs) / (ze - zs)) : 1
            // Resistance builds through the draw, then the snap force at the end zone.
            return (z >= ze ? s2 : s * t, 0)
        case .galloping:
            return (0, z >= zs && z < ze && frequency > 0 ? 0.6 : 0)
        case .machine:
            guard z >= zs, z < ze, frequency > 0 else { return (0, 0) }
            return (0, max(Double(strength), Double(secondStrength)) / 7)
        }
    }

    // MARK: Presets

    struct Preset: Identifiable, Sendable {
        let id: String
        let symbol: String
        let detail: String
        let design: TriggerDesign
    }

    static let presets: [Preset] = [
        Preset(id: "Weapon trigger", symbol: "scope", detail: "Resistance that breaks at zone 5, like a trigger sear.",
               design: TriggerDesign(family: .weapon, start: 2, end: 5, strength: 8)),
        Preset(id: "Bow draw", symbol: "arrow.up.right", detail: "Tension builds through the draw, then snaps back.",
               design: TriggerDesign(family: .bow, start: 1, end: 6, strength: 6, secondStrength: 8)),
        Preset(id: "Brake", symbol: "car.side", detail: "A ramp from light to firm across the pull.",
               design: TriggerDesign(family: .slope, start: 0, end: 9, strength: 1, secondStrength: 8)),
        Preset(id: "Click / detent", symbol: "dial.medium", detail: "A single firm notch halfway down.",
               design: TriggerDesign(family: .zoneFeedback, zones: [0, 0, 0, 0, 8, 0, 0, 0, 0, 0])),
        Preset(id: "Machine gun", symbol: "burst", detail: "Rapid vibration alternating between two strengths.",
               design: TriggerDesign(family: .machine, start: 2, end: 9, strength: 7, secondStrength: 2, frequency: 9, period: 1)),
        Preset(id: "Off", symbol: "circle.slash", detail: "No resistance.", design: .off),
    ]

    // MARK: Code

    /// A Swift expression building this effect through the Tactile factories.
    var swiftExpression: String {
        switch family {
        case .off: ".off"
        case .feedback: "try .feedback(position: \(start), strength: \(strength))"
        case .weapon: "try .weapon(start: \(start), end: \(end), strength: \(strength))"
        case .vibration: "try .vibration(position: \(start), amplitude: \(strength), frequency: \(frequency))"
        case .slope: "try .slopeFeedback(startPosition: \(start), endPosition: \(end), startStrength: \(strength), endStrength: \(secondStrength))"
        case .zoneFeedback: "try .multiplePositionFeedback(strengths: \(zones))"
        case .zoneVibration: "try .multiplePositionVibration(frequency: \(frequency), amplitudes: \(zones))"
        case .bow: "try .bow(start: \(start), end: \(end), strength: \(strength), snapForce: \(secondStrength))"
        case .galloping: "try .galloping(start: \(start), end: \(end), firstFoot: \(firstFoot), secondFoot: \(secondFoot), frequency: \(frequency))"
        case .machine: "try .machine(start: \(start), end: \(end), amplitudeA: \(strength), amplitudeB: \(secondStrength), frequency: \(frequency), period: \(period))"
        }
    }

    var summary: String {
        switch family {
        case .off: "Off"
        case .zoneFeedback, .zoneVibration: "\(family.title) \(zones.map(String.init).joined(separator: ","))"
        default: "\(family.title) \(start)→\(end) · \(strength)"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
