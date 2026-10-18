import SwiftUI
import Tactile

struct TriggerEditor: View {
    var session: LabSession
    @State private var preset = "Feedback"
    @State private var side = HapticSide.both
    @State private var start = 3
    @State private var end = 7
    @State private var strength = 4
    @State private var secondStrength = 6
    @State private var frequency = 30
    @State private var period = 4
    @State private var firstFoot = 2
    @State private var secondFoot = 5
    @State private var zones = "0,0,2,3,4,5,6,6,6,6"
    @State private var raw = "05 00 00 00 00 00 00 00 00 00 00"
    private let presets = ["Off", "Feedback", "Weapon", "Vibration", "Slope", "Per-zone feedback", "Per-zone vibration", "Bow (unofficial)", "Galloping (unofficial)", "Machine (unofficial)", "Raw bytes"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Preset", selection: $preset) { ForEach(presets, id: \.self) { Text($0) } }
                Picker("Side", selection: $side) { ForEach(HapticSide.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 200)
            }
            if preset == "Raw bytes" {
                TextField("Exactly 11 hexadecimal bytes", text: $raw).textFieldStyle(.roundedBorder).font(.body.monospaced())
            } else if preset.hasPrefix("Per-zone") {
                TextField("Ten zone strengths (0–8), separated by commas", text: $zones).textFieldStyle(.roundedBorder)
                if preset == "Per-zone vibration" { number("Frequency 0–255 Hz", value: $frequency) }
            } else if preset != "Off" {
                HStack { number("Start / position 0–9", value: $start); number("Strength / amplitude 0–8", value: $strength) }
                if ["Weapon", "Slope", "Bow (unofficial)", "Galloping (unofficial)", "Machine (unofficial)"].contains(preset) {
                    HStack { number("End zone 0–9", value: $end); number("End / snap / B strength", value: $secondStrength) }
                }
                if ["Vibration", "Galloping (unofficial)", "Machine (unofficial)"].contains(preset) {
                    HStack { number("Frequency 0–255 Hz", value: $frequency); if preset == "Machine (unofficial)" { number("Period (tenths of a second)", value: $period) } }
                }
                if preset == "Galloping (unofficial)" { HStack { number("First foot 0–6", value: $firstFoot); number("Second foot 1–7", value: $secondFoot) } }
            }
            HStack {
                if case .failure(let error) = validated { Text(String(describing: error)).font(.caption).foregroundStyle(.orange) }
                else { Text(preset.contains("unofficial") || preset == "Raw bytes" ? "Experimental firmware behavior; observe the physical result." : "Parameters are validated before sending.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Test Triggers") { apply() }.disabled(!session.canOperate || isInvalid).accessibilityIdentifier("testTriggers")
            }
        }
    }

    private func number(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption)
            TextField(label, value: value, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var isInvalid: Bool { if case .failure = validated { true } else { false } }
    private var validated: Result<TriggerEffect, any Error> { Result { try effect() } }
    private func effect() throws -> TriggerEffect {
        switch preset {
        case "Off": return .off
        case "Feedback": return try .feedback(position: start, strength: strength)
        case "Weapon": return try .weapon(start: start, end: end, strength: strength)
        case "Vibration": return try .vibration(position: start, amplitude: strength, frequency: frequency)
        case "Slope": return try .slopeFeedback(startPosition: start, endPosition: end, startStrength: strength, endStrength: secondStrength)
        case "Per-zone feedback", "Per-zone vibration":
            let values = zones.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 10, values.allSatisfy({ $0 != nil }) else { throw LabError.invalid("Enter exactly ten integer strengths.") }
            let strengths = values.compactMap { $0 }
            return try preset == "Per-zone feedback" ? .multiplePositionFeedback(strengths: strengths) : .multiplePositionVibration(frequency: frequency, amplitudes: strengths)
        case "Bow (unofficial)": return try .bow(start: start, end: end, strength: strength, snapForce: secondStrength)
        case "Galloping (unofficial)": return try .galloping(start: start, end: end, firstFoot: firstFoot, secondFoot: secondFoot, frequency: frequency)
        case "Machine (unofficial)": return try .machine(start: start, end: end, amplitudeA: strength, amplitudeB: secondStrength, frequency: frequency, period: period)
        default:
            let bytes = raw.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16) }
            guard bytes.count == 11, bytes.allSatisfy({ $0 != nil }) else { throw LabError.invalid("Raw effects require exactly 11 hexadecimal bytes.") }
            return TriggerEffect(rawBytes: bytes.compactMap { $0 })
        }
    }
    private func apply() {
        do {
            let effect = try effect()
            let output = OutputState(leftTrigger: side == .right ? nil : effect, rightTrigger: side == .left ? nil : effect)
            session.perform(.output(output), name: "Adaptive triggers", settings: "preset=\(preset), side=\(side.rawValue), bytes=\(effect.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        } catch { session.showError(error) }
    }
}
