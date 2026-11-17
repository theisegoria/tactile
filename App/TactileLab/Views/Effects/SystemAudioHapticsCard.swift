import AppKit
import SwiftUI
import Tactile
import TactileSystemAudio

/// Drives the actuators from system audio or one app's audio through the
/// library's `SystemAudioHapticsSource` and `HapticFilterChain`. Capture runs
/// as a session operation (up to the 60 s operation limit, Stop All ends it)
/// and needs the Screen Recording permission. In simulation it is unavailable
/// and never starts capture.
struct SystemAudioHapticsCard: View {
    @Bindable var session: LabSession
    @State private var monitor = SystemAudioMonitor()
    @State private var permission = SystemAudioHapticsSource.hasPermission
    @State private var apps: [SystemAudioHapticsSource.AudioApplication] = []
    @State private var appsError: String?
    @AppStorage("systemAudioTarget") private var targetID = ""
    @State private var filter = HapticFilterSettings.music
    @State private var showAdvanced = false

    static let operationName = "System audio haptics"
    private var running: Bool { session.activeOperation == Self.operationName }
    private var available: Bool { !session.simulated && permission }

    var body: some View {
        LabCard(title: "System audio to haptics", symbol: "hifispeaker.and.homepod",
                subtitle: "Feel what the Mac plays: all system audio or one app, filtered for the actuators.") {
            if running {
                Button("Stop", systemImage: "stop.fill") { Task { await session.stopAll() } }
                    .buttonStyle(.glassProminent).tint(.red)
                    .accessibilityIdentifier("systemAudioStop")
            } else {
                Button("Start", systemImage: "play.fill") { start() }
                    .buttonStyle(.glassProminent)
                    .disabled(!available || !session.canOperate)
                    .help(session.simulated ? "Unavailable in simulation" : "Capture for up to 60 s; Stop or Stop All ends it")
                    .accessibilityIdentifier("systemAudioStart")
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                status
                if !session.simulated {
                    Picker("Source", selection: $targetID) {
                        Text("All system audio").tag("")
                        if !targetID.isEmpty, !apps.contains(where: { $0.bundleIdentifier == targetID }) {
                            Text(targetID).tag(targetID)
                        }
                        ForEach(apps) { Text($0.name).tag($0.bundleIdentifier) }
                    }
                    .disabled(running || !permission)
                    .accessibilityIdentifier("systemAudioTarget")
                    if let appsError { Text(appsError).font(.caption).foregroundStyle(.secondary) }
                }
                Picker("Filter", selection: presetBinding) {
                    ForEach(SystemAudioPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("systemAudioPreset")
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced.padding(.top, 6) }
                meters
            }
        }
        .onAppear(perform: refreshPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
        .task(id: available) { await loadApps() }
        .onChange(of: filter) { _, new in monitor.updateFilter(new) }
        .accessibilityIdentifier("systemAudioCard")
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if session.simulated {
            Label("Unavailable in simulation: system audio capture never starts while simulating.", systemImage: "nosign")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("systemAudioUnavailable")
        } else if !permission {
            VStack(alignment: .leading, spacing: 6) {
                Label("Screen Recording permission needed", systemImage: "lock.shield").font(.callout.weight(.medium))
                Text("macOS delivers other apps' audio through ScreenCaptureKit, which sits behind the Screen & System Audio Recording permission. Tactile Lab captures audio only; no screen content is recorded. After granting, you may need to relaunch the app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Request Permission") {
                        SystemAudioHapticsSource.requestPermission()
                        refreshPermission()
                    }
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Check Again") { refreshPermission() }
                }
                .buttonStyle(.glass)
            }
            .accessibilityIdentifier("systemAudioPermission")
        } else {
            Label("Screen Recording permission granted", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Filter

    private var presetBinding: Binding<SystemAudioPreset> {
        Binding(get: { SystemAudioPreset.matching(filter) },
                set: { preset in if let settings = preset.settings { filter = settings } else { showAdvanced = true } })
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Band", selection: $filter.mode) {
                Text("None").tag(HapticFilterSettings.FilterMode.none)
                Text("Low-pass").tag(HapticFilterSettings.FilterMode.lowPass)
                Text("Band-pass").tag(HapticFilterSettings.FilterMode.bandPass)
            }
            .pickerStyle(.segmented)
            if filter.mode == .bandPass { ValueSlider(title: "Low cut (Hz)", value: $filter.lowCutoff, range: 10...500) }
            if filter.mode != .none { ValueSlider(title: "High cut (Hz)", value: $filter.highCutoff, range: 50...1400) }
            ValueSlider(title: "Input gain (dB)", value: float(\.inputGainDB), range: -24...24)
            ValueSlider(title: "Compressor (dBFS)", value: float(\.compressorThresholdDB), range: -60...0)
            ValueSlider(title: "Ratio", value: float(\.compressorRatio), range: 1...20, precision: 1)
            ValueSlider(title: "Attack (ms)", value: milliseconds(\.compressorAttack), range: 0.5...100, precision: 1)
            ValueSlider(title: "Release (ms)", value: milliseconds(\.compressorRelease), range: 10...1000)
            ValueSlider(title: "Makeup gain (dB)", value: float(\.makeupGainDB), range: 0...24)
            ValueSlider(title: "Gate (dBFS)", value: gate, range: -120...0)
            Text(filter.gateThresholdDB <= -120 ? "Gate off." : "Quieter signals are muted.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func float(_ path: WritableKeyPath<HapticFilterSettings, Float>) -> Binding<Double> {
        Binding(get: { Double(filter[keyPath: path]) }, set: { filter[keyPath: path] = Float($0) })
    }

    private func milliseconds(_ path: WritableKeyPath<HapticFilterSettings, Double>) -> Binding<Double> {
        Binding(get: { filter[keyPath: path] * 1000 }, set: { filter[keyPath: path] = $0 / 1000 })
    }

    private var gate: Binding<Double> {
        Binding(get: { filter.gateThresholdDB.isFinite ? max(-120, Double(filter.gateThresholdDB)) : -120 },
                set: { filter.gateThresholdDB = $0 <= -120 ? -.infinity : Float($0) })
    }

    // MARK: Meters

    private var meters: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let level = running ? monitor.level : 0
            let reduction = running ? monitor.gainReductionDB : 0
            let db = 20 * log10(max(Double(level), 1e-6))
            VStack(alignment: .leading, spacing: 4) {
                meter("Level", fraction: (db + 60) / 60, text: level > 0 ? String(format: "%.0f dBFS", db) : "—", tint: .green)
                meter("Gain reduction", fraction: Double(reduction) / 24, text: String(format: "%.1f dB", reduction), tint: .orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("systemAudioMeters")
    }

    private func meter(_ title: String, fraction: Double, text: String, tint: Color) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 110, alignment: .leading)
            Gauge(value: max(0, min(1, fraction.isFinite ? fraction : 0))) { EmptyView() }
                .gaugeStyle(.linearCapacity).tint(tint)
            Text(text).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
        }
    }

    // MARK: Actions

    private func refreshPermission() { permission = SystemAudioHapticsSource.hasPermission }

    private func loadApps() async {
        guard available else { apps = []; return }
        do {
            apps = try await SystemAudioHapticsSource.capturableApplications()
            appsError = nil
        } catch {
            appsError = "Could not list apps: \(error.localizedDescription)"
        }
    }

    private func start() {
        guard available else { return }
        let target: SystemAudioHapticsSource.Target = targetID.isEmpty ? .allSystemAudio : .application(bundleIdentifier: targetID)
        let name = targetID.isEmpty ? "all system audio" : (apps.first { $0.bundleIdentifier == targetID }?.name ?? targetID)
        // One operation length for the session; capture for the 60 s limit, then restore it.
        let previous = session.duration
        session.duration = 60
        session.perform(.systemAudio(SystemAudioRequest(target: target, filter: filter, monitor: monitor)),
                        name: Self.operationName, settings: "source=\(name); \(SystemAudioPreset.matching(filter).rawValue): \(filter.summary)")
        session.duration = previous
    }
}
