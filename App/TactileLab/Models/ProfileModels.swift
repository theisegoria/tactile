import Foundation
import Tactile

/// Who a profile is for. Named `LabProfile*` so it does not clash with the
/// Tactile library's forthcoming `ControllerProfile`; convert in one adapter
/// once that type exists.
enum LabProfileScope: Sendable, Hashable, Codable {
    case general
    case game(String)
    case player(Int)

    var label: String {
        switch self {
        case .general: "General"
        case .game(let name): name.isEmpty ? "Game" : name
        case .player(let n): "Player \(n)"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .game: "gamecontroller"
        case .player: "person.crop.circle"
        }
    }
}

/// An editable adaptive-trigger setting. Kept as parameters (not wire bytes)
/// so the profile editor can show and change them; `raw` carries effects
/// imported from elsewhere byte for byte.
struct LabProfileTrigger: Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case off, feedback, weapon, vibration, raw
        var label: String {
            switch self {
            case .off: "Off"
            case .feedback: "Resistance"
            case .weapon: "Weapon"
            case .vibration: "Vibration"
            case .raw: "Custom bytes"
            }
        }
    }
    var kind: Kind = .off
    /// feedback: position 0–9, strength 1–8. weapon: start 2–7, end start+1–8, strength 1–8.
    /// vibration: position 0–9, amplitude 1–8, frequency 1–255.
    var a = 3
    var b = 4
    var c = 30
    var rawBytes: [UInt8]?

    static let off = LabProfileTrigger()

    /// The wire effect, or nil when the parameters are out of range.
    var effect: TriggerEffect? {
        switch kind {
        case .off: return .off
        case .feedback: return try? TriggerEffect.feedback(position: a, strength: b)
        case .weapon: return try? TriggerEffect.weapon(start: a, end: b, strength: c)
        case .vibration: return try? TriggerEffect.vibration(position: a, amplitude: b, frequency: c)
        case .raw: return rawBytes.map(TriggerEffect.init(rawBytes:))
        }
    }

    var summary: String {
        switch kind {
        case .off: "off"
        case .feedback: "resistance from zone \(a), strength \(b)"
        case .weapon: "weapon \(a)–\(b), strength \(c)"
        case .vibration: "vibration from zone \(a), amplitude \(b), \(c) Hz"
        case .raw: "bytes \((rawBytes ?? []).map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
    }

    /// Sensible defaults when the editor switches kind.
    static func defaults(for kind: Kind) -> LabProfileTrigger {
        switch kind {
        case .off: .off
        case .feedback: LabProfileTrigger(kind: .feedback, a: 3, b: 4, c: 0)
        case .weapon: LabProfileTrigger(kind: .weapon, a: 3, b: 6, c: 6)
        case .vibration: LabProfileTrigger(kind: .vibration, a: 2, b: 4, c: 30)
        case .raw: LabProfileTrigger(kind: .raw, a: 0, b: 0, c: 0, rawBytes: [TriggerEffect.Mode.off.rawValue])
        }
    }
}

/// A named set of controller outputs: lightbar, player LEDs, triggers and haptic gain.
struct LabProfile: Sendable, Hashable, Codable, Identifiable {
    var id = UUID()
    var name: String
    var scope: LabProfileScope = .general
    var lightbar = LightbarColor(red: 0, green: 120, blue: 255)
    /// Player LED pattern 0 (off) to 5, as `PlayerLEDs.player(_:)`.
    var playerLEDs = 1
    var brightness = LEDBrightness.high
    var muteLED = MuteLED.off
    var leftTrigger = LabProfileTrigger.off
    var rightTrigger = LabProfileTrigger.off
    /// Gain for audio-driven haptics, 0–4 (1 is unity).
    var hapticGain = 1.0
    var createdAt = Date()
    var modifiedAt = Date()

    /// The output report this profile requests. Rumble is never part of a profile.
    var outputState: OutputState {
        OutputState(leftTrigger: leftTrigger.effect, rightTrigger: rightTrigger.effect, lightbar: lightbar,
                    playerLEDs: .player(playerLEDs), playerLEDBrightness: brightness, muteLED: muteLED)
    }

    var summary: String {
        "lightbar #\(lightbar.hex); player LEDs \(playerLEDs == 0 ? "off" : "\(playerLEDs)"); brightness \(String(describing: brightness)); mute \(String(describing: muteLED)); L2 \(leftTrigger.summary); R2 \(rightTrigger.summary); haptic gain \(String(format: "%.2f", hapticGain))"
    }

    /// Validation messages; empty when the profile can be applied.
    var problems: [String] {
        var list: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.append("Give the profile a name.") }
        if leftTrigger.effect == nil { list.append("L2 settings are out of range.") }
        if rightTrigger.effect == nil { list.append("R2 settings are out of range.") }
        if !(0...5).contains(playerLEDs) { list.append("Player LEDs must be 0–5.") }
        if !hapticGain.isFinite || !(0...4).contains(hapticGain) { list.append("Haptic gain must be 0–4.") }
        return list
    }
}

extension LightbarColor {
    var hex: String { String(format: "%02X%02X%02X", red, green, blue) }
}
