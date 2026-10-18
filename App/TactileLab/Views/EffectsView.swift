import AppKit
import AVFoundation
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
        Form {
            Section { DurationControl(session: session) }
            Section("Lightbar and LEDs") {
                HStack {
                    ColorPicker("Lightbar", selection: $light, supportsOpacity: false)
                    Picker("Player", selection: $player) { Text("Off").tag(0); ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }.frame(width: 150)
                    Picker("Brightness", selection: $brightness) { Text("High").tag(LEDBrightness.high); Text("Medium").tag(LEDBrightness.medium); Text("Low").tag(LEDBrightness.low) }.frame(width: 190)
                }
                HStack {
                    Picker("Mute LED", selection: $mute) { Text("Off").tag(MuteLED.off); Text("On").tag(MuteLED.on); Text("Pulse").tag(MuteLED.pulse) }.frame(width: 220)
                    Spacer()
                    Button("Test Lights") { testLights() }.disabled(!session.canOperate).accessibilityIdentifier("testLights")
                }
            }
            Section("Independent rumble") {
                ValueSlider(title: "Left actuator", value: $leftRumble, range: 0...255)
                ValueSlider(title: "Right actuator", value: $rightRumble, range: 0...255)
                HStack {
                    Text("Legacy compatible vibration").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Rumble") {
                        session.perform(.output(OutputState(rumble: Rumble(left: UInt8(leftRumble), right: UInt8(rightRumble)))), name: "Rumble", settings: "left=\(Int(leftRumble)), right=\(Int(rightRumble))")
                    }.disabled(!session.canOperate).accessibilityIdentifier("testRumble")
                }
            }
            Section("Adaptive triggers") { TriggerEditor(session: session) }
            Section("Parametric haptics") {
                HStack {
                    Picker("Effect", selection: $haptic) { ForEach(["Tone", "Click", "Detent", "Texture", "Impact"], id: \.self) { Text($0) } }
                    Picker("Actuators", selection: $hapticSide) { ForEach(HapticSide.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                }
                ValueSlider(title: "Intensity", value: $intensity, range: 0...1, precision: 2)
                if ["Tone", "Click", "Detent"].contains(haptic) { ValueSlider(title: "Frequency (Hz)", value: $frequency, range: 30...400) }
                if haptic == "Texture" { ValueSlider(title: "Grains per second", value: $grainRate, range: 1...200) }
                Button("Test Haptics") { testHaptics() }.disabled(!session.canOperate).accessibilityIdentifier("testHaptics")
            }
            Section("Audio-driven haptics") {
                ValueSlider(title: "Gain", value: $gain, range: 0...4, precision: 2)
                HStack {
                    Button("Choose Audio File…") { file = AudioFiles.choose() }
                    Text(file?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Play as Haptics") {
                        if let file { session.perform(.hapticFile(file, Float(gain)), name: "File haptics", settings: "file=\(file.lastPathComponent), gain=\(gain)") }
                    }.disabled(file == nil || !session.canOperate)
                }
                HStack {
                    Text("Host microphone: \(session.microphonePermission == .authorized ? "allowed" : "permission required")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Host Microphone Haptics") { microphone() }.disabled(!session.canOperate)
                }
            }
        }.formStyle(.grouped)
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
    private func microphone() {
        let id = session.selectedID
        Task {
            let permitted = session.simulated || (await AVCaptureDevice.requestAccess(for: .audio))
            session.refreshPermissions()
            guard permitted else { session.showError(LabError.invalid("Allow Microphone access in System Settings → Privacy & Security → Microphone.")); return }
            guard session.selectedID == id else { return }
            session.perform(.hostMicrophone(Float(gain)), name: "Host microphone haptics", settings: "host microphone, gain=\(gain)")
        }
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
