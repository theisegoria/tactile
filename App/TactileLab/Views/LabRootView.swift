import SwiftUI
import Tactile

struct LabRootView: View {
    @Bindable var session: LabSession
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.permission != .granted && !session.simulated { permissionBanner }
            if let error = session.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).accessibilityIdentifier("operationError")
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { session.clearError() }.labelStyle(.iconOnly)
                }.padding(12).background(.orange.opacity(0.08))
            }
            TabView(selection: $session.tab) {
                Tab("Input", systemImage: "gamecontroller", value: .input) { InputView(session: session) }
                Tab("Effects", systemImage: "waveform.path", value: .effects) { EffectsView(session: session) }
                Tab("Audio", systemImage: "speaker.wave.2", value: .audio) { AudioView(session: session) }
                Tab("Diagnostics", systemImage: "stethoscope", value: .diagnostics) { DiagnosticsView(session: session) }
                Tab("Tests", systemImage: "checklist", value: .tests) { TestsView(session: session) }
            }
            .padding(.top, 10)
            Divider()
            HStack {
                Text(session.status).lineLimit(2).accessibilityIdentifier("sessionStatus")
                Spacer()
                ReportRateLabel(readings: session.readings)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .toolbar {
            ToolbarItem { Button("Export Session", systemImage: "square.and.arrow.up") { session.exportReport() } }
            ToolbarItem {
                Button("Connection Options", systemImage: "slider.horizontal.3") { showAdvanced.toggle() }
                    .popover(isPresented: $showAdvanced) { connectionOptions }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Picker("Controller", selection: Binding(get: { session.selectedID ?? "" }, set: { session.select($0.isEmpty ? nil : $0) })) {
                    Text("Select a controller").tag("")
                    ForEach(session.devices) { device in
                        Text("\(device.name) · \(device.id.suffix(8))\(device.connected ? "" : " (offline)")").tag(device.id)
                    }
                }.labelsHidden().frame(minWidth: 260, maxWidth: 360).accessibilityLabel("Selected controller").accessibilityIdentifier("selectedController")
                HStack(spacing: 10) {
                    Label(session.selectedDevice?.connected == true ? "Bluetooth connected" : "Bluetooth idle", systemImage: "antenna.radiowaves.left.and.right")
                    if session.simulated { Text("SIMULATED").fontWeight(.semibold).foregroundStyle(.orange).accessibilityIdentifier("simulationBadge") }
                    ControllerBatteryLabel(readings: session.readings)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                Text(session.activeOperation ?? "No active operation").font(.callout).lineLimit(1).accessibilityIdentifier("activeOperation")
                Text("Effects start only when requested").font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { Task { await session.stopAll() } } label: {
                Label("Stop All", systemImage: "stop.fill")
            }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).accessibilityIdentifier("stopAll")
        }.padding(16)
    }

    private var permissionBanner: some View {
        HStack {
            Label("Input Monitoring: \(session.permission.rawValue)", systemImage: "hand.raised")
            Spacer()
            Button("Request Access") { session.requestPermission() }
            Button("Open Settings") { InputMonitoringPermission.openSystemSettings() }
            Button("Retry") { Task { await session.reconnect() } }
        }.padding(12).background(.yellow.opacity(0.08))
    }

    private var connectionOptions: some View {
        Form {
            Section("Connection") {
                Toggle("Exclusive access", isOn: $session.exclusive)
                Text("Exclusive access temporarily removes the controller from other apps. Apply reconnects in order and stops current output.").font(.caption).foregroundStyle(.secondary)
                Button("Apply and Reconnect") { showAdvanced = false; Task { await session.reconnect() } }
            }
            Section("Simulation") {
                Toggle("Simulated controller", isOn: Binding(get: { session.simulated }, set: { enabled in Task { await session.setSimulation(enabled) } }))
                Text("Simulation sends no HID output. Its observations are labeled in exports.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Bluetooth Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) } }
        }.formStyle(.grouped).frame(width: 360, height: 340)
    }
}

/// Frequent telemetry reads stay outside the parent view that owns native menus.
private struct ControllerBatteryLabel: View {
    var readings: LiveReadings
    var body: some View {
        if let battery = readings.input?.battery {
            Label("\(battery.percent)%", systemImage: battery.charging == .charging ? "battery.100percent.bolt" : "battery.75percent")
        }
    }
}

private struct ReportRateLabel: View {
    var readings: LiveReadings
    var body: some View { Text("Local session · \(readings.rate, specifier: "%.0f") Hz").monospacedDigit() }
}

struct DurationControl: View {
    @Bindable var session: LabSession
    var body: some View {
        HStack {
            Label("Test duration", systemImage: "timer")
            TextField("Seconds", value: $session.duration, format: .number)
                .labelsHidden().frame(width: 65).textFieldStyle(.roundedBorder).accessibilityIdentifier("testDuration")
            Text("seconds (0.1–60)").foregroundStyle(.secondary)
        }
    }
}
