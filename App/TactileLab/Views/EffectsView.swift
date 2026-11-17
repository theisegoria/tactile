import AppKit
import SwiftUI
import Tactile
import UniformTypeIdentifiers

struct EffectsView: View {
    @Bindable var session: LabSession
    @State private var light = Color.cyan
    @State private var player = 1
    @State private var mute = MuteLED.off
    @State private var brightness = LEDBrightness.high
    @State private var leftRumble = 80.0
    @State private var rightRumble = 80.0
    @State private var haptic = "Tone"
    @State private var hapticSide = HapticSide.both
    @State private var intensity = 0.25
    @State private var frequency = 160.0
    @State private var grainRate = 60.0
    @State private var gain = 1.0
    @State private var file: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabScreenHeader(title: "Effects",
                                detail: "Quick tests of every output: lights, rumble, adaptive triggers and haptics. Each test runs for the test length in the toolbar; Stop All returns everything to neutral.")
                NoControllerNotice(session: session)
                lightsCard
                rumbleCard
                LabCard(title: "Adaptive triggers", symbol: "l2.button.angledtop.vertical.left",
                        subtitle: "Validated presets and raw bytes. The Trigger Designer draws the curve and has a preset gallery.") {
                    TriggerEditor(session: session)
                }
                hapticsCard
                audioHapticsCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("effectsView")
    }

    private var lightsCard: some View {
        LabCard(title: "Lightbar and LEDs", symbol: "light.strip.2", subtitle: "Colour, player indicator, brightness and mute LED.") {
            Button("Test Lights", systemImage: "lightbulb") { testLights() }
                .buttonStyle(.glassProminent)
                .disabled(!session.canOperate)
                .accessibilityIdentifier("testLights")
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { lightControls }
                VStack(alignment: .leading, spacing: 8) { lightControls }
            }
        }
    }

    @ViewBuilder private var lightControls: some View {
        ColorPicker("Lightbar", selection: $light, supportsOpacity: false).fixedSize()
        Picker("Player LEDs", selection: $player) { Text("Off").tag(0); ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }
            .fixedSize().help("Pattern on the five player LEDs (1–5)")
        Picker("Brightness", selection: $brightness) { Text("High").tag(LEDBrightness.high); Text("Medium").tag(LEDBrightness.medium); Text("Low").tag(LEDBrightness.low) }
            .fixedSize()
        Picker("Mute LED", selection: $mute) { Text("Off").tag(MuteLED.off); Text("On").tag(MuteLED.on); Text("Pulse").tag(MuteLED.pulse) }
            .fixedSize()
    }

    private var rumbleCard: some View {
        LabCard(title: "Independent rumble", symbol: "water.waves", subtitle: "Legacy compatible vibration, one level per motor (0–255).") {
            Button("Test Rumble", systemImage: "play.fill") {
                session.perform(.output(OutputState(rumble: Rumble(left: UInt8(leftRumble), right: UInt8(rightRumble)))), name: "Rumble", settings: "left=\(Int(leftRumble)), right=\(Int(rightRumble))")
            }
            .buttonStyle(.glassProminent)
            .disabled(!session.canOperate)
            .accessibilityIdentifier("testRumble")
        } content: {
            VStack(spacing: 6) {
                ValueSlider(title: "Left actuator", value: $leftRumble, range: 0...255)
                ValueSlider(title: "Right actuator", value: $rightRumble, range: 0...255)
            }
        }
    }

    private var hapticsCard: some View {
        LabCard(title: "Parametric haptics", symbol: "waveform.path", subtitle: "Synthesised at 3 kHz on the voice-coil actuators. Felt result unverified until you try it.") {
            Button("Test Haptics", systemImage: "play.fill") { testHaptics() }
                .buttonStyle(.glassProminent)
                .disabled(!session.canOperate)
                .accessibilityIdentifier("testHaptics")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Picker("Effect", selection: $haptic) { ForEach(["Tone", "Click", "Detent", "Texture", "Impact"], id: \.self) { Text($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 380)
                    Picker("Actuators", selection: $hapticSide) { ForEach(HapticSide.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        .fixedSize()
                }
                ValueSlider(title: "Intensity", value: $intensity, range: 0...1, precision: 2)
                if ["Tone", "Click", "Detent"].contains(haptic) { ValueSlider(title: "Frequency (Hz)", value: $frequency, range: 30...400) }
                if haptic == "Texture" { ValueSlider(title: "Grains per second", value: $grainRate, range: 1...200) }
            }
        }
    }

    private var audioHapticsCard: some View {
        LabCard(title: "Audio-driven haptics", symbol: "waveform", subtitle: "Plays an audio file, or the Mac's microphone, into the actuators.") {
            Button("Play as Haptics", systemImage: "play.fill") {
                if let file { session.perform(.hapticFile(file, Float(gain)), name: "File haptics", settings: "file=\(file.lastPathComponent), gain=\(gain)") }
            }
            .buttonStyle(.glassProminent)
            .disabled(file == nil || !session.canOperate)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ValueSlider(title: "Gain", value: $gain, range: 0...4, precision: 2)
                HStack {
                    Button("Choose Audio File…") { file = AudioFiles.choose() }.buttonStyle(.glass)
                    Text(file?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    Label("Host microphone: \(session.microphonePermission == .authorized ? "allowed" : "permission required")",
                          systemImage: session.microphonePermission == .authorized ? "mic" : "mic.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Host Microphone Haptics") { session.requestHostMicrophoneHaptics(gain: Float(gain)) }
                        .buttonStyle(.glass)
                        .disabled(!session.canOperate)
                }
            }
        }
    }

    private func testLights() {
        guard let color = NSColor(light).usingColorSpace(.sRGB) else { return }
        let rgb = LightbarColor(red: UInt8(max(0, min(1, color.redComponent)) * 255), green: UInt8(max(0, min(1, color.greenComponent)) * 255), blue: UInt8(max(0, min(1, color.blueComponent)) * 255))
        session.perform(.output(OutputState(lightbar: rgb, playerLEDs: .player(player), playerLEDBrightness: brightness, muteLED: mute)), name: "Lightbar and LEDs", settings: "RGB=\(rgb.red)/\(rgb.green)/\(rgb.blue); player=\(player); mute=\(mute.rawValue); brightness=\(brightness.rawValue)")
    }
    private func testHaptics() {
        let effect: HapticEffect = switch haptic {
        case "Click": .click(intensity: Float(intensity), frequency: Float(frequency))
        case "Detent": .detent(intensity: Float(intensity), frequency: Float(frequency))
        case "Texture": .texture(intensity: Float(intensity), grainRate: Float(grainRate), duration: session.duration)
        case "Impact": .impact(intensity: Float(intensity))
        default: .tone(intensity: Float(intensity), frequency: Float(frequency), duration: session.duration)
        }
        session.perform(.haptic(effect, hapticSide), name: haptic, settings: "side=\(hapticSide.rawValue), intensity=\(intensity), frequency=\(frequency), grainRate=\(grainRate)")
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var precision = 0
    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range).accessibilityLabel(title)
            Text(value, format: .number.precision(.fractionLength(precision))).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
}

@MainActor enum AudioFiles {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a short audio clip. Playback is bounded by the test duration."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
