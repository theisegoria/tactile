import AppKit
import SwiftUI
import Tactile

/// Shared empty states for screens that need a connected controller.
///
/// Usage in any screen:
/// ```swift
/// if let kind = LabEmptyState.kind(for: session) {
///     LabEmptyStateView(kind: kind, session: session)
/// }
/// ```
enum LabEmptyState: Equatable {
    case permissionDenied
    case noController

    /// The empty state the session is in, or nil when a controller is connected and selected.
    @MainActor static func kind(for session: LabSession) -> LabEmptyState? {
        // The simulated "denied" scenario reports .denied too, so it previews this state.
        if session.permission == .denied { return .permissionDenied }
        if session.selectedDevice?.connected != true { return .noController }
        return nil
    }
}

struct LabEmptyStateView<Extra: View>: View {
    let kind: LabEmptyState
    var session: LabSession
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        switch kind {
        case .noController: NoControllerEmptyState(session: session, extra: extra)
        case .permissionDenied: PermissionDeniedEmptyState(session: session, extra: extra)
        }
    }
}

extension LabEmptyStateView where Extra == EmptyView {
    init(kind: LabEmptyState, session: LabSession) { self.init(kind: kind, session: session, extra: { EmptyView() }) }
}

/// No controller connected: pairing steps, Bluetooth Settings, retry, simulation.
struct NoControllerEmptyState<Extra: View>: View {
    var session: LabSession
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ContentUnavailableView {
            Label("No Controller Connected", systemImage: "gamecontroller")
        } description: {
            Text("Pair a DualSense or DualSense Edge over Bluetooth: hold **PS** and **Create** until the light bar flashes, then choose it in Bluetooth Settings.")
        } actions: {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Bluetooth Settings", systemImage: "antenna.radiowaves.left.and.right") { LabSystemSettings.openBluetooth() }
                        .buttonStyle(.glassProminent)
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await session.reconnect() } }
                        .buttonStyle(.glass)
                    if !session.simulated {
                        Button("Use Simulation", systemImage: "testtube.2") { Task { await session.setSimulation(true) } }
                            .buttonStyle(.glass)
                    }
                    extra()
                }
            }
        }
        .accessibilityIdentifier("emptyStateNoController")
    }
}

extension NoControllerEmptyState where Extra == EmptyView {
    init(session: LabSession) { self.init(session: session, extra: { EmptyView() }) }
}

/// Input Monitoring denied: explain, open System Settings, retry.
struct PermissionDeniedEmptyState<Extra: View>: View {
    var session: LabSession
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ContentUnavailableView {
            Label("Input Monitoring Is Off", systemImage: "hand.raised.slash")
        } description: {
            Text("Tactile Lab reads controller input through Input Monitoring. Turn on Tactile Lab in System Settings → Privacy & Security → Input Monitoring, then retry.")
        } actions: {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Open Settings", systemImage: "gear") { InputMonitoringPermission.openSystemSettings() }
                        .buttonStyle(.glassProminent)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        session.refreshPermissions()
                        Task { await session.reconnect() }
                    }
                    .buttonStyle(.glass)
                    extra()
                }
            }
        }
        .accessibilityIdentifier("emptyStatePermissionDenied")
    }
}

extension PermissionDeniedEmptyState where Extra == EmptyView {
    init(session: LabSession) { self.init(session: session, extra: { EmptyView() }) }
}

@MainActor enum LabSystemSettings {
    static func openBluetooth() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }
}
