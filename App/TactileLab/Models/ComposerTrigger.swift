import Foundation
import Tactile

/// An editable adaptive-trigger design: one effect family plus its parameters,
/// flat so the parameter editor can bind to every field. The Trigger Designer
/// and the Composer's trigger track share it. Everything else comes from the
/// library: `spec` is the `TriggerEffectSpec`, `effect()` validates through
/// it, `curve` is `TriggerCurve`, presets are `TriggerPreset`, code is
/// `TactileCodeExport`.
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

    func effect() throws -> TriggerEffect { try spec.effect() }

    var validationMessage: String? {
        do { _ = try effect(); return nil } catch { return Self.describe(error) }
    }

    static func describe(_ error: any Error) -> String {
        if let v = error as? TriggerEffect.ValidationError { return String(describing: v) }
        return (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Library spec

    /// The library's description of this design (Tactile 0.4). Curves, presets
    /// and code export all come from the spec.
    var spec: TriggerEffectSpec {
        switch family {
        case .off: .off
        case .feedback: .feedback(position: start, strength: strength)
        case .weapon: .weapon(start: start, end: end, strength: strength)
        case .vibration: .vibration(position: start, amplitude: strength, frequency: frequency)
        case .slope: .slopeFeedback(startPosition: start, endPosition: end, startStrength: strength, endStrength: secondStrength)
        case .zoneFeedback: .multiplePositionFeedback(strengths: zones)
        case .zoneVibration: .multiplePositionVibration(frequency: frequency, amplitudes: zones)
        case .bow: .bow(start: start, end: end, strength: strength, snapForce: secondStrength)
        case .galloping: .galloping(start: start, end: end, firstFoot: firstFoot, secondFoot: secondFoot, frequency: frequency)
        case .machine: .machine(start: start, end: end, amplitudeA: strength, amplitudeB: secondStrength, frequency: frequency, period: period)
        }
    }

    /// Resistance and vibration over travel, from the library's `TriggerCurve`
    /// (a reading of the parameters, not a measurement of the motor).
    var curve: TriggerCurve { spec.curve }

    // MARK: Presets

    /// The library's presets with the symbols and wording the gallery shows.
    struct Preset: Identifiable, Sendable {
        let preset: TriggerPreset
        var id: String { preset.displayName }
        var design: TriggerDesign { TriggerDesign(spec: preset.spec) }
        var symbol: String {
            switch preset {
            case .off: "circle.slash"
            case .weaponTrigger: "scope"
            case .bowDraw: "arrow.up.right"
            case .brakePedal: "car.side"
            case .clickDetent: "dial.medium"
            case .machineGun: "burst"
            case .gallop: "hare"
            }
        }
        var detail: String {
            switch preset {
            case .off: "No resistance."
            case .weaponTrigger: "Resistance that breaks partway down, like a trigger sear."
            case .bowDraw: "Tension builds through the draw, then snaps back."
            case .brakePedal: "A ramp from light to firm across the pull."
            case .clickDetent: "A short, sharp notch halfway down."
            case .machineGun: "Rapid vibration alternating between two strengths."
            case .gallop: "Two taps per cycle, like hooves."
            }
        }
    }

    /// Every `TriggerPreset`, with Off last.
    static let presets: [Preset] = TriggerPreset.allCases.filter { $0 != .off }.map(Preset.init) + [Preset(preset: .off)]

    /// The preset this design matches exactly, if any.
    var matchingPreset: TriggerPreset? { TriggerPreset.allCases.first { $0.spec == spec } }

    // MARK: Code

    /// Source for this design on `side` in `language` (Tactile 0.4 code export).
    func code(side: TriggerSide, language: CodeLanguage) -> String {
        if let preset = matchingPreset { return TactileCodeExport.trigger(preset, side: side, language: language) }
        return TactileCodeExport.trigger(spec, side: side, language: language)
    }

    var summary: String {
        switch family {
        case .off: "Off"
        case .zoneFeedback, .zoneVibration: "\(family.title) \(zones.map(String.init).joined(separator: ","))"
        default: "\(family.title) \(start)→\(end) · \(strength)"
        }
    }
}

extension TriggerDesign {
    /// The editable design for a library spec. Raw bytes have no editable
    /// family: they are decoded back to a factory where the library can,
    /// otherwise the design is off.
    init(spec: TriggerEffectSpec) {
        self.init()
        switch spec {
        case .off: family = .off
        case let .feedback(p, s): family = .feedback; start = p; strength = s
        case let .weapon(s, e, st): family = .weapon; start = s; end = e; strength = st
        case let .vibration(p, a, f): family = .vibration; start = p; strength = a; frequency = f
        case let .slopeFeedback(sp, ep, ss, es): family = .slope; start = sp; end = ep; strength = ss; secondStrength = es
        case let .multiplePositionFeedback(s): family = .zoneFeedback; zones = Self.tenZones(s)
        case let .multiplePositionVibration(f, a): family = .zoneVibration; frequency = f; zones = Self.tenZones(a)
        case let .bow(s, e, st, sn): family = .bow; start = s; end = e; strength = st; secondStrength = sn
        case let .galloping(s, e, f1, f2, f): family = .galloping; start = s; end = e; firstFoot = f1; secondFoot = f2; frequency = f
        case let .machine(s, e, a, b, f, p): family = .machine; start = s; end = e; strength = a; secondStrength = b; frequency = f; period = p
        case let .raw(bytes):
            let decoded = TriggerEffectSpec(decoding: TriggerEffect(rawBytes: bytes))
            if case .raw = decoded { family = .off } else { self = TriggerDesign(spec: decoded) }
        }
    }

    private static func tenZones(_ values: [Int]) -> [Int] {
        Array((values + Array(repeating: 0, count: 10)).prefix(10))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
