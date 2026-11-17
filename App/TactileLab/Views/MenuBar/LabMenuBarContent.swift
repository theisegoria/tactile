import AppKit
import SwiftUI
import Tactile

/// Content for the Tactile Lab menu bar extra (window style, Liquid Glass):
/// connected controllers with battery, the active profile with a switcher,
/// Stop All, and Open Tactile Lab.
///
/// Scene to add in `TactileLabApp.body`, after the `Window("Tactile Lab", id: "lab")` scene:
/// ```swift
/// MenuBarExtra {
///     LabMenuBarContent(session: session)
/// } label: {
///     LabMenuBarLabel(session: session)
/// }
/// .menuBarExtraStyle(.window)
/// ```
/// `LabMenuBarContent` opens the main window with `openWindow(id: "lab")`, so
/// the window id must stay "lab". Consider returning false from
/// `applicationShouldTerminateAfterLastWindowClosed` so the menu bar item
/// outlives the window (today the app quits when the window closes).
struct LabMenuBarContent: View {
    var session: LabSession
    var profiles: LabProfileStore
    @Environment(\.openWindow) private var openWindow

    init(session: LabSession, profiles: LabProfileStore? = nil) {
        self.session = session
        self.profiles = profiles ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tactile Lab", systemImage: "gamecontroller.fill").font(.headline)
                Spacer()
                if session.simulated {
                    Text("SIMULATED").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
                }
            }
            controllers
            profileSection
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(role: .destructive) { Task { await session.stopAll() } } label: {
                        Label("Stop All", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("menuBarStopAll")
                    Button { openLab() } label: {
                        Label("Open Tactile Lab", systemImage: "macwindow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("menuBarOpenLab")
                }
            }
            Divider()
            HStack {
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var controllers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controllers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if session.devices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: session.permission == .denied ? "hand.raised.slash" : "gamecontroller").foregroundStyle(.tertiary)
                    Text(session.permission == .denied ? "Input Monitoring is off" : "No controller connected").foregroundStyle(.secondary)
                }
                .font(.callout).padding(.vertical, 4)
            } else {
                ForEach(session.devices) { device in
                    LabMenuBarControllerRow(session: session, board: session.board, device: device)
                }
            }
        }
    }

    @ViewBuilder private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profile").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if profiles.profiles.isEmpty {
                Text("No profiles yet. Create one in Tactile Lab.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    if let active = profiles.activeProfile {
                        Circle().fill(Color(active.lightbar)).frame(width: 10, height: 10)
                    }
                    Picker("Active profile", selection: Binding(
                        get: { profiles.activeID },
                        set: { id in
                            if let id, let profile = profiles.profiles.first(where: { $0.id == id }) { profiles.apply(profile, to: session) }
                            else { profiles.setActive(nil) }
                        })) {
                        Text("None").tag(UUID?.none)
                        ForEach(profiles.profiles) { profile in Text(profile.name).tag(UUID?.some(profile.id)) }
                    }
                    .labelsHidden()
                    .disabled(!session.canOperate)
                    .accessibilityIdentifier("menuBarProfile")
                }
                if !session.canOperate {
                    Text("Connect a controller to apply a profile.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openLab() {
        openWindow(id: "lab")
        NSApp.activate()
    }
}

/// One controller: model, connection, battery. Reads the throttled player board.
private struct LabMenuBarControllerRow: View {
    var session: LabSession
    var board: PlayerBoard
    let device: LabDevice

    var body: some View {
        let battery = board.readings[device.id]?.battery ?? (device.id == session.selectedID ? session.readings.input?.battery : nil)
        Button { session.select(device.id) } label: {
            HStack(spacing: 10) {
                if let player = session.player(of: device.id) {
                    PlayerDot(player: player, color: Color(session.playerColor(player)), size: 20)
                } else {
                    Image(systemName: "gamecontroller").frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName).lineLimit(1)
                    Text(device.connected ? (device.id == session.selectedID ? "Connected · selected" : "Connected") : "Disconnected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let battery, device.connected {
                    Label("\(battery.percent)%", systemImage: LabMenuBarLabel.batterySymbol(battery))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(battery.percent <= 20 && battery.charging == .discharging ? .red : .secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(device.connected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .glassEffect(device.id == session.selectedID ? .regular.tint(.accentColor.opacity(0.2)) : .regular, in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("menuBarController-\(device.id)")
    }
}

/// Menu bar icon: a controller glyph, filled while an effect is running.
struct LabMenuBarLabel: View {
    var session: LabSession
    var body: some View {
        Image(systemName: session.activeOperation == nil ? "gamecontroller" : "gamecontroller.fill")
            .accessibilityLabel("Tactile Lab")
    }

    static func batterySymbol(_ battery: BatteryStatus) -> String {
        switch battery.charging {
        case .charging: return "battery.100percent.bolt"
        case .full: return "battery.100percent"
        default:
            switch battery.percent {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }
}
