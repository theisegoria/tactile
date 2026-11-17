import AppKit
import SwiftUI
import Tactile

/// Create or edit a profile: lightbar, player LEDs, mute LED, both triggers and haptic gain.
struct ProfileEditorSheet: View {
    @State var profile: LabProfile
    let title: String
    var onSave: (LabProfile) -> Void
    var onTry: ((LabProfile) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum ScopeKind: String, CaseIterable { case general = "General", game = "Game", player = "Player" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name).accessibilityIdentifier("profileName")
                    Picker("For", selection: scopeKind) { ForEach(ScopeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    switch profile.scope {
                    case .game(let name):
                        TextField("Game", text: Binding(get: { name }, set: { profile.scope = .game($0) }), prompt: Text("Game title"))
                    case .player(let n):
                        Stepper("Player \(n)", value: Binding(get: { n }, set: { profile.scope = .player($0) }), in: 1...8)
                    case .general:
                        EmptyView()
                    }
                }
                Section("Lightbar and LEDs") {
                    ColorPicker("Lightbar", selection: lightbarColor, supportsOpacity: false)
                    Picker("Player LEDs", selection: $profile.playerLEDs) {
                        Text("Off").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Brightness", selection: $profile.brightness) {
                        Text("High").tag(LEDBrightness.high); Text("Medium").tag(LEDBrightness.medium); Text("Low").tag(LEDBrightness.low)
                    }
                    Picker("Mute LED", selection: $profile.muteLED) {
                        Text("Off").tag(MuteLED.off); Text("On").tag(MuteLED.on); Text("Pulse").tag(MuteLED.pulse)
                    }
                }
                Section("Adaptive triggers") {
                    ProfileTriggerEditor(title: "L2", trigger: $profile.leftTrigger)
                    ProfileTriggerEditor(title: "R2", trigger: $profile.rightTrigger)
                }
                Section {
                    LabeledContent("Haptic gain") {
                        HStack {
                            Slider(value: $profile.hapticGain, in: 0...1).accessibilityLabel("Haptic gain")
                            Text(profile.hapticGain, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
                        }
                    }
                } header: { Text("Haptics") } footer: {
                    Text("Master gain for every haptic the Lab sends while this profile is active; 1.00 is full strength.").font(.caption).foregroundStyle(.secondary)
                }
                if !profile.problems.isEmpty {
                    Section {
                        ForEach(profile.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let onTry {
                    Button("Try on Controller", systemImage: "play") { onTry(profile) }
                        .disabled(!profile.problems.isEmpty)
                        .help("Apply for the test length without saving")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(profile); dismiss() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!profile.problems.isEmpty)
                    .accessibilityIdentifier("profileSave")
            }
            .padding(16)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560, idealHeight: 640)
        .navigationTitle(title)
    }

    private var scopeKind: Binding<ScopeKind> {
        Binding {
            switch profile.scope { case .general: .general; case .game: .game; case .player: .player }
        } set: { kind in
            switch kind {
            case .general: profile.scope = .general
            case .game: if case .game = profile.scope {} else { profile.scope = .game("") }
            case .player: if case .player = profile.scope {} else { profile.scope = .player(1) }
            }
        }
    }

    private var lightbarColor: Binding<Color> {
        Binding {
            Color(profile.lightbar)
        } set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ v: CGFloat) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
            profile.lightbar = LightbarColor(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent))
        }
    }
}

/// Kind picker plus the parameters that kind needs.
struct ProfileTriggerEditor: View {
    let title: String
    @Binding var trigger: LabProfileTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: Binding(get: { trigger.kind }, set: { trigger = .defaults(for: $0) })) {
                ForEach(LabProfileTrigger.Kind.allCases.filter { $0 != .raw || trigger.kind == .raw }, id: \.self) { Text($0.label).tag($0) }
            }
            switch trigger.kind {
            case .off:
                EmptyView()
            case .feedback:
                stepper("Starts at zone", $trigger.a, 0...9)
                stepper("Strength", $trigger.b, 1...8)
            case .weapon:
                stepper("Start zone", $trigger.a, 2...7)
                stepper("End zone", $trigger.b, 3...8)
                stepper("Strength", $trigger.c, 1...8)
            case .vibration:
                stepper("Starts at zone", $trigger.a, 0...9)
                stepper("Amplitude", $trigger.b, 1...8)
                stepper("Frequency (Hz)", $trigger.c, 1...255)
            case .raw:
                Text(trigger.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func stepper(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack { Text(label); Spacer(); Text("\(value.wrappedValue)").monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}
