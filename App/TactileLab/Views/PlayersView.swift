import SwiftUI
import Tactile

/// Overview of every connected controller as a numbered player, for local
/// multiplayer and split-screen testing.
struct PlayersView: View {
    @Bindable var session: LabSession
    /// Two columns: four players read as the four quadrants of a split screen.
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(1...session.slots.capacity, id: \.self) { player in
                        PlayerCard(session: session, board: session.board, player: player)
                    }
                }
                Label("Every controller shares the Mac's Bluetooth radio. Audio haptics on several controllers at once has not been measured on hardware.",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("playersView")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Players").font(.title2.weight(.semibold))
                Text("Up to \(session.slots.capacity) controllers for local multiplayer and split screen. A controller that disconnects keeps its seat and returns as the same player.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Toggle("Show player lights", isOn: Binding(get: { session.playerLights }, set: { session.setPlayerLights($0) }))
                .toggleStyle(.switch)
                .help("Light each controller's player LEDs with its number and its lightbar with the player colour.")
                .accessibilityIdentifier("playerLights")
        }
    }
}

private struct PlayerCard: View {
    @Bindable var session: LabSession
    var board: PlayerBoard
    let player: Int

    private var device: LabDevice? { session.device(forPlayer: player) }
    private var color: Color { Color(session.playerColor(player)) }
    private var selected: Bool { device != nil && device?.id == session.selectedID }
    private var identifying: Bool { device.map { board.identifying.contains($0.id) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlayerBadge(player: player, color: color, dimmed: device?.connected != true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device?.model ?? "Player \(player)").font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let device { actions(device) }
            }
            if let device, device.connected {
                LiveSummary(reading: board.readings[device.id] ?? PlayerReading(), color: color)
            } else if device != nil {
                placeholder("Disconnected — seat held", detail: "Switch the controller back on to rejoin as player \(player).", symbol: "pause.circle")
            } else {
                placeholder("Waiting for a controller", detail: "Pair one in Bluetooth settings or press its PS button.", symbol: "plus.circle.dashed")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(device == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(color.opacity(selected ? 0.9 : 0.35)),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: device == nil ? [5, 4] : []))
        }
        .scaleEffect(identifying ? 1.015 : 1)
        .shadow(color: identifying ? color.opacity(0.45) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.2), value: identifying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerCard\(player)")
    }

    private var subtitle: String {
        guard let device else { return "Empty seat" }
        var parts = [device.connected ? "Connected" : "Seat held"]
        if let id = device.shortID { parts.append(id) }
        if device.simulated { parts.append("Simulated") }
        if selected { parts.append("Inspecting") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func actions(_ device: LabDevice) -> some View {
        HStack(spacing: 6) {
            Button("Identify", systemImage: "dot.radiowaves.left.and.right") { session.identify(device.id) }
                .labelStyle(.iconOnly).help("Rumble briefly so you can tell which controller this is")
                .disabled(!device.connected)
            Button("Inspect", systemImage: "scope") { session.inspect(device.id) }
                .labelStyle(.iconOnly).help("Open this controller in Input, Effects and the other tabs")
                .disabled(!device.connected)
            Menu {
                ForEach(1...session.slots.capacity, id: \.self) { target in
                    Button("Player \(target)") { session.assignPlayer(device.id, to: target) }.disabled(target == player)
                }
                Divider()
                Button("Free This Seat", role: .destructive) { session.releasePlayer(player) }
            } label: {
                Label("Move", systemImage: "arrow.left.arrow.right")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Move to another player number (swaps with whoever is there)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private func placeholder(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct PlayerBadge: View {
    let player: Int
    let color: Color
    var dimmed: Bool
    var body: some View {
        Text("P\(player)")
            .font(.system(.title3, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(color.gradient).opacity(dimmed ? 0.35 : 1))
            .accessibilityLabel("Player \(player)")
    }
}

/// Compact live readout: sticks, triggers, pressed buttons, battery.
private struct LiveSummary: View {
    let reading: PlayerReading
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            MiniStick(value: reading.leftStick, color: color, label: "L")
            MiniStick(value: reading.rightStick, color: color, label: "R")
            VStack(alignment: .leading, spacing: 8) {
                TriggerBar(label: "L2", value: reading.l2, color: color)
                TriggerBar(label: "R2", value: reading.r2, color: color)
                pressed
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                if let b = reading.battery {
                    Label("\(b.percent)%", systemImage: b.charging == .charging ? "battery.100percent.bolt" : "battery.75percent")
                }
                Text("\(reading.rate, specifier: "%.0f") Hz").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.secondary)
            .offset(y: 22)
        }
        .padding(.bottom, 18)
    }

    private var pressed: some View {
        let names = ButtonNames.short(reading.buttons)
        return HStack(spacing: 4) {
            if names.isEmpty {
                Text("No buttons pressed").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(names.prefix(5), id: \.self) { name in
                    Text(name).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.18)))
                }
                if names.count > 5 { Text("+\(names.count - 5)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(height: 18)
    }
}

private struct MiniStick: View {
    let value: SIMD2<UInt8>
    let color: Color
    let label: String
    var body: some View {
        let x = (CGFloat(value.x) - 128) / 128, y = (CGFloat(value.y) - 128) / 128
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.quaternary)
                Circle().strokeBorder(.separator)
                Circle().fill(color).frame(width: 12, height: 12).offset(x: x * 22, y: y * 22)
            }
            .frame(width: 58, height: 58)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label == "L" ? "Left" : "Right") stick \(value.x), \(value.y)")
    }
}

private struct TriggerBar: View {
    let label: String
    let value: UInt8
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            ProgressView(value: Double(value), total: 255).tint(color).frame(width: 110)
        }
    }
}

enum ButtonNames {
    static func short(_ b: Buttons) -> [String] {
        let all: [(Buttons, String)] = [
            (.cross, "✕"), (.circle, "○"), (.square, "□"), (.triangle, "△"),
            (.dpadUp, "↑"), (.dpadDown, "↓"), (.dpadLeft, "←"), (.dpadRight, "→"),
            (.l1, "L1"), (.r1, "R1"), (.l3, "L3"), (.r3, "R3"),
            (.create, "Create"), (.options, "Options"), (.ps, "PS"), (.touchpad, "Pad"), (.mute, "Mute"),
            (.fnLeft, "Fn1"), (.fnRight, "Fn2"), (.paddleLeft, "LB"), (.paddleRight, "RB"),
        ]
        return all.filter { b.contains($0.0) }.map(\.1)
    }
}

extension Color {
    init(_ c: LightbarColor) {
        self.init(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }
}
