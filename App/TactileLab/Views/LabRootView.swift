import SwiftUI
import Tactile

struct LabRootView: View {
    @Bindable var session: LabSession
    @State private var showAdvanced = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detail
                .navigationTitle(session.tab.rawValue)
                .navigationSubtitle(subtitle)
        }
        .onAppear {
            // macOS gives the first text field (the toolbar's test length) focus
            // when the window opens; start with nothing focused instead.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Controller", selection: Binding(get: { session.selectedID ?? "" }, set: { session.select($0.isEmpty ? nil : $0) })) {
                    Text("Select a controller").tag("")
                    ForEach(session.devices) { device in
                        Text("\(device.displayName)\(device.connected ? "" : " (offline)")").tag(device.id)
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Selected controller").accessibilityIdentifier("selectedController")
            }
            ToolbarItem(placement: .primaryAction) { DurationControl(session: session) }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { Task { await session.stopAll() } } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent).tint(.red)
                .accessibilityIdentifier("stopAll")
                .help("Stop every effect and return outputs to neutral (⌘.)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Export Session", systemImage: "square.and.arrow.up") { session.exportReport() }
                Button("Connection Options", systemImage: "slider.horizontal.3") { showAdvanced.toggle() }
                    .popover(isPresented: $showAdvanced) { connectionOptions }
            }
        }
    }

    private var subtitle: String {
        guard let device = session.selectedDevice else { return "No controller selected" }
        return device.connected ? "Bluetooth connected" : "Bluetooth idle"
    }

    private var sidebar: some View {
        List(selection: Binding(get: { session.tab }, set: { if let t = $0 { session.tab = t } })) {
            Section("Lab") {
                ForEach(LabTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            if !session.devices.isEmpty {
                Section("Controllers") {
                    ForEach(session.devices) { device in
                        ControllerRow(session: session, device: device)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.simulated {
                HStack(spacing: 6) {
                    Image(systemName: "testtube.2").accessibilityHidden(true)
                    Text("SIMULATED").accessibilityIdentifier("simulationBadge")
                }
                .font(.callout.weight(.bold)).foregroundStyle(.orange)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
                .help("Simulation sends no controller output")
                .padding(12)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if session.permission != .granted && !session.simulated { permissionBanner }
            if let error = session.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).accessibilityIdentifier("operationError")
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { session.clearError() }.labelStyle(.iconOnly)
                }
                .padding(12)
                .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
                .padding([.horizontal, .top], 16)
            }
            Group {
                switch session.tab {
                case .input: InputView(session: session)
                case .composer: ComposerView(session: session)
                case .triggers: TriggerDesignerView(session: session)
                case .inputLab: InputLabView(session: session)
                case .profiles: ProfilesView(session: session)
                case .effects: EffectsView(session: session)
                case .audio: AudioView(session: session)
                case .diagnostics: DiagnosticsView(session: session)
                case .tests: TestsView(session: session)
                case .players: PlayersView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                operationPill(compact: false)
                Divider().frame(height: 14)
                Text(session.status).lineLimit(1).accessibilityIdentifier("sessionStatus")
                Spacer(minLength: 12)
                ControllerBatteryLabel(readings: session.readings)
                ReportRateLabel(readings: session.readings)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16).padding(.bottom, 12)
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
        .help("Effects start only when you request them. Stop All returns every output to neutral.")
    }

    private var permissionBanner: some View {
        HStack {
            Label("Input Monitoring: \(session.permission.rawValue)", systemImage: "hand.raised")
            Spacer()
            Button("Request Access") { session.requestPermission() }
            Button("Open Settings") { InputMonitoringPermission.openSystemSettings() }
            Button("Retry") { Task { await session.reconnect() } }
        }
        .padding(12)
        .glassEffect(.regular.tint(.yellow.opacity(0.15)), in: .rect(cornerRadius: 16))
        .padding([.horizontal, .top], 16)
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

/// A controller in the sidebar: its player number, model and connection; click to inspect it.
private struct ControllerRow: View {
    @Bindable var session: LabSession
    let device: LabDevice

    var body: some View {
        let player = session.player(of: device.id)
        Button { session.select(device.id) } label: {
            HStack(spacing: 10) {
                if let player { PlayerDot(player: player, color: Color(session.playerColor(player)), size: 22) }
                else { Image(systemName: "gamecontroller").frame(width: 22) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.model).lineLimit(1)
                    Text(device.connected ? "Connected" : "Disconnected · seat held").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if device.id == session.selectedID { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.tint) }
            }
            .opacity(device.connected ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(device.displayName)\(player.map { " — player \($0)" } ?? "")")
        .accessibilityIdentifier(player.map { "playerChip\($0)" } ?? "controller-\(device.id)")
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
                .labelsHidden().frame(width: 40).multilineTextAlignment(.trailing)
                .textFieldStyle(.plain).accessibilityIdentifier("testDuration")
                .accessibilityLabel("Test length in seconds")
            Text("s").foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 6)
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
