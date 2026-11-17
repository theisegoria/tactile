import SwiftUI
import Tactile

/// Edits a `TriggerDesign`: family, then only the parameters that family
/// uses, with the library's ranges. Shared by the Trigger Designer and the
/// Composer inspector.
struct TriggerParameterEditor: View {
    @Binding var design: TriggerDesign

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Effect", selection: $design.family) {
                ForEach(TriggerDesign.Family.allCases) { family in
                    Text(family.isUnofficial ? "\(family.title) (unofficial)" : family.title).tag(family)
                }
            }
            switch design.family {
            case .off:
                Text("No resistance or vibration.").font(.caption).foregroundStyle(.secondary)
            case .feedback:
                IntSlider(title: "Start zone", value: $design.start, range: 0...9)
                IntSlider(title: "Strength", value: $design.strength, range: 0...8)
            case .weapon:
                IntSlider(title: "Start zone", value: $design.start, range: 2...7)
                IntSlider(title: "Break zone", value: $design.end, range: 0...8)
                IntSlider(title: "Strength", value: $design.strength, range: 0...8)
            case .vibration:
                IntSlider(title: "Start zone", value: $design.start, range: 0...9)
                IntSlider(title: "Amplitude", value: $design.strength, range: 0...8)
                IntSlider(title: "Frequency (Hz)", value: $design.frequency, range: 0...255)
            case .slope:
                IntSlider(title: "Start zone", value: $design.start, range: 0...8)
                IntSlider(title: "End zone", value: $design.end, range: 0...9)
                IntSlider(title: "Start strength", value: $design.strength, range: 1...8)
                IntSlider(title: "End strength", value: $design.secondStrength, range: 1...8)
            case .zoneFeedback, .zoneVibration:
                ZoneEditor(zones: $design.zones)
                if design.family == .zoneVibration { IntSlider(title: "Frequency (Hz)", value: $design.frequency, range: 0...255) }
            case .bow:
                IntSlider(title: "Start zone", value: $design.start, range: 0...8)
                IntSlider(title: "End zone", value: $design.end, range: 0...8)
                IntSlider(title: "Strength", value: $design.strength, range: 0...8)
                IntSlider(title: "Snap force", value: $design.secondStrength, range: 0...8)
            case .galloping:
                IntSlider(title: "Start zone", value: $design.start, range: 0...8)
                IntSlider(title: "End zone", value: $design.end, range: 0...9)
                IntSlider(title: "First foot", value: $design.firstFoot, range: 0...6)
                IntSlider(title: "Second foot", value: $design.secondFoot, range: 0...7)
                IntSlider(title: "Frequency (Hz)", value: $design.frequency, range: 0...255)
            case .machine:
                IntSlider(title: "Start zone", value: $design.start, range: 1...8)
                IntSlider(title: "End zone", value: $design.end, range: 0...9)
                IntSlider(title: "Amplitude A", value: $design.strength, range: 0...7)
                IntSlider(title: "Amplitude B", value: $design.secondStrength, range: 0...7)
                IntSlider(title: "Frequency (Hz)", value: $design.frequency, range: 0...255)
                IntSlider(title: "Period (0.1 s)", value: $design.period, range: 0...255)
            }
            if let message = design.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if design.family.isUnofficial {
                Label("Unofficial mode: experimental firmware behaviour. Observe the physical result.", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct IntSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(title)
            Text("\(value)").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

/// Ten vertical zone strengths (0–8), dragged like a graphic equaliser.
struct ZoneEditor: View {
    @Binding var zones: [Int]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let level = Double(zones[safe: i] ?? 0) / 8
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.gradient)
                                .frame(height: geo.size.height * level)
                        }
                        .contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            let v = Int(((1 - drag.location.y / max(1, geo.size.height)) * 8).rounded())
                            set(i, max(0, min(8, v)))
                        })
                    }
                    .frame(height: 70)
                    Text("\(zones[safe: i] ?? 0)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement()
                .accessibilityLabel("Zone \(i)")
                .accessibilityValue("\(zones[safe: i] ?? 0)")
                .accessibilityAdjustableAction { direction in
                    let v = zones[safe: i] ?? 0
                    set(i, max(0, min(8, direction == .increment ? v + 1 : v - 1)))
                }
            }
        }
    }

    private func set(_ i: Int, _ v: Int) {
        var z = zones
        while z.count < 10 { z.append(0) }
        guard z[i] != v else { return }
        z[i] = v
        zones = z
    }
}
