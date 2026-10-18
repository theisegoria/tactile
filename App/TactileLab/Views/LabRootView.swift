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
                Tab("Players", systemImage: "person.2", value: .players) { PlayersView(session: session) }
            }
            .padding(.top, 10)
            Divider()
            HStack {
                Text(session.status).lineLimit(2).accessibilityIdentifier("sessionStatus")
                Spacer()
                ReportRateLabel(readings: session.readings)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .onAppear {
            // macOS gives the first text field (the header's test length) focus
            // when the window opens; start with nothing focused instead.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let player = session.selectedID.flatMap(session.player(of:)) {
                        PlayerDot(player: player, color: Color(session.playerColor(player)))
                    }
                    Picker("Controller", selection: Binding(get: { session.selectedID ?? "" }, set: { session.select($0.isEmpty ? nil : $0) })) {
                        Text("Select a controller").tag("")
                        ForEach(session.devices) { device in
                            Text("\(device.displayName)\(device.connected ? "" : " (offline)")").tag(device.id)
                        }
                    }.labelsHidden().fixedSize().frame(minWidth: 210, alignment: .leading).accessibilityLabel("Selected controller").accessibilityIdentifier("selectedController")
                }
                HStack(spacing: 10) {
                    Label(session.selectedDevice?.connected == true ? "Bluetooth connected" : "Bluetooth idle", systemImage: "antenna.radiowaves.left.and.right")
                    if session.simulated {
                        Text("SIMULATED").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(.orange.opacity(0.6)))
                            .accessibilityIdentifier("simulationBadge")
                    }
                    ControllerBatteryLabel(readings: session.readings)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if session.devices.count > 1 {
                // Full labels when there is room, numbered dots otherwise.
                ViewThatFits(in: .horizontal) {
                    playerChips(compact: false)
                    playerChips(compact: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    operationPill(compact: false)
                    operationPill(compact: true)
                }
                DurationControl(session: session)
                Button(role: .destructive) { Task { await session.stopAll() } } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).accessibilityIdentifier("stopAll")
                    .help("Stop every effect and return outputs to neutral (⌘.)")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Quick switching between connected controllers, labelled by player.
    private func playerChips(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(1...session.slots.capacity, id: \.self) { player in
                if let device = session.device(forPlayer: player) {
                    let selected = device.id == session.selectedID
                    Button { session.select(device.id) } label: {
                        HStack(spacing: 5) {
                            PlayerDot(player: player, color: Color(session.playerColor(player)), size: 18)
                            if !compact {
                                Text(device.model == "DualSense Edge" ? "Edge" : "DualSense").lineLimit(1).fixedSize()
                            }
                        }
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, compact ? 4 : 8).padding(.vertical, 4)
                        .background(Capsule().fill(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.6))))
                        .opacity(device.connected ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .help("\(device.displayName) — player \(player)\(device.connected ? "" : " (disconnected, seat held)")")
                    .accessibilityIdentifier("playerChip\(player)")
                }
            }
        }
    }

    private func operationPill(compact: Bool) -> some View {
        let active = session.activeOperation
        return HStack(spacing: 6) {
            Circle().fill(active == nil ? Color.secondary.opacity(0.4) : .green).frame(width: 7, height: 7)
            if !compact {
                Text(active ?? "No active operation").lineLimit(1).accessibilityIdentifier("activeOperation")
            }
        }
        .accessibilityElement(children: compact ? .ignore : .contain)
        .accessibilityLabel(compact ? (active ?? "No active operation") : "")
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .help("Effects start only when you request them. Stop All returns every output to neutral.")
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
        HStack(spacing: 4) {
            Image(systemName: "timer").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Seconds", value: $session.duration, format: .number)
                .labelsHidden().frame(width: 46).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("testDuration")
                .accessibilityLabel("Test length in seconds")
            Text("s").foregroundStyle(.secondary)
        }
        .help("Length of every output test, 0.1–60 seconds")
    }
}

struct PlayerDot: View {
    let player: Int
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Text("\(player)")
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
            .accessibilityLabel("Player \(player)")
    }
}
