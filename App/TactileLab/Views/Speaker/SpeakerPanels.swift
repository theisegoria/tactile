import SwiftUI
import Tactile

/// Swift counterpart of the C ABI's `tactile_controller_info` (0.3): IDs,
/// product string, firmware and the `TACTILE_CAP_*` capability set with the
/// unverified subset. Built the same way as `capabilities()` in
/// TactileCABI/Exports.swift; like the library, it marks every capability
/// unverified until confirmed on hardware.
struct ControllerCapabilities: Sendable, Equatable {
    struct Capability: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let available: Bool
        let unverified: Bool
        var note: String?
    }

    var model: ControllerModel
    var transport: Transport
    var vendorID: UInt32 = DeviceIDs.sonyVendorID
    var productID: UInt32
    var product: String
    var address: String
    var firmware: FirmwareInfo?
    var vibrationV2: Bool
    var simulated: Bool
    var capabilities: [Capability]

    static func make(model: ControllerModel, transport: Transport, product: String?, address: String?, firmware: FirmwareInfo?,
                     vibrationV2: Bool, speakerFramingAvailable: Bool, simulated: Bool) -> ControllerCapabilities {
        let bluetooth = transport == .bluetooth
        // Nothing is confirmed on hardware yet (PROTOCOL.md): every bit is unverified.
        let caps: [Capability] = [
            .init(id: "triggers", title: "Adaptive triggers", symbol: "l2.button.angledtop.vertical.left", available: true, unverified: true),
            .init(id: "lights", title: "Lightbar, player and mute LEDs", symbol: "light.strip.2", available: true, unverified: true),
            .init(id: "imu", title: "Calibrated motion (IMU)", symbol: "gyroscope", available: true, unverified: true),
            .init(id: "touchpad", title: "Touchpad", symbol: "hand.point.up.left", available: true, unverified: true),
            .init(id: "rumble", title: "Legacy rumble", symbol: "water.waves", available: true, unverified: true),
            .init(id: "vibrationV2", title: "Compatible vibration 2", symbol: "waveform.path.ecg", available: vibrationV2, unverified: true,
                  note: vibrationV2 ? nil : "Firmware uses the legacy rumble flag"),
            .init(id: "edge", title: "Fn and back paddles", symbol: "button.programmable", available: model == .dualSenseEdge, unverified: true),
            .init(id: "hidHaptics", title: "Audio haptics (report 0x32)", symbol: "waveform", available: bluetooth, unverified: true,
                  note: bluetooth ? nil : "USB: haptics play on the pad's USB audio device"),
            .init(id: "usbHaptics", title: "USB audio haptics", symbol: "cable.connector", available: !bluetooth, unverified: true),
            .init(id: "hidSpeaker", title: "Speaker (report 0x36)", symbol: "speaker.wave.2", available: bluetooth && speakerFramingAvailable, unverified: true,
                  note: bluetooth && !speakerFramingAvailable ? "The report descriptor declares no usable 0x36" : nil),
            .init(id: "usbSpeaker", title: "USB speaker and jack", symbol: "cable.connector", available: !bluetooth, unverified: true),
            .init(id: "routing", title: "Audio routing and volumes", symbol: "slider.horizontal.3", available: true, unverified: true),
            .init(id: "headset", title: "Headset and mic detection", symbol: "headphones", available: true, unverified: true),
        ]
        return ControllerCapabilities(model: model, transport: transport, productID: model.productID,
                                      product: product ?? (model == .dualSenseEdge ? "DualSense Edge Wireless Controller" : "DualSense Wireless Controller"),
                                      address: address ?? "", firmware: firmware, vibrationV2: vibrationV2, simulated: simulated, capabilities: caps)
    }

    @MainActor
    static func collect(_ session: LabSession) async -> ControllerCapabilities? {
        guard let device = session.selectedDevice else { return nil }
        if let c = session.selectedController {
            let features = await c.connection?.features
            let address = await c.address?.description
            return make(model: c.model, transport: c.transport, product: c.info.product, address: address,
                        firmware: session.diagnostics.firmware, vibrationV2: features?.vibrationV2 == true,
                        speakerFramingAvailable: (c.speakerFraming()?.maxPacketBytes ?? 0) > 0, simulated: false)
        }
        guard device.simulated else { return nil }
        let model = ControllerModel.allCases.first { $0.displayName == device.model } ?? .dualSense
        return make(model: model, transport: .bluetooth, product: nil, address: nil, firmware: nil,
                    vibrationV2: true, speakerFramingAvailable: true, simulated: true)
    }
}

/// Capabilities card: IDs, product, firmware and each capability with its
/// verification state.
struct CapabilitiesCard: View {
    var session: LabSession
    @State private var info: ControllerCapabilities?

    var body: some View {
        LabCard(title: "Capabilities", symbol: "checklist", subtitle: subtitle) {
            if info?.simulated == true { LabTag(text: "Simulated", symbol: "testtube.2", tint: .blue) }
        } content: {
            if let info {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Vendor / product").foregroundStyle(.secondary); Text(String(format: "0x%04X / 0x%04X", info.vendorID, info.productID)).monospacedDigit() }
                        GridRow { Text("Product").foregroundStyle(.secondary); Text(info.product).lineLimit(1) }
                        GridRow { Text("Transport").foregroundStyle(.secondary); Text(info.transport == .bluetooth ? "Bluetooth" : "USB") }
                        if !info.address.isEmpty { GridRow { Text("Address").foregroundStyle(.secondary); Text(info.address).monospaced() } }
                        if let fw = info.firmware {
                            GridRow { Text("Firmware").foregroundStyle(.secondary); Text(String(format: "0x%08X · hw 0x%08X · update %d.%02d", fw.firmwareVersion, fw.hardwareVersion, fw.updateVersion >> 8, fw.updateVersion & 0xFF)).monospacedDigit() }
                        }
                    }
                    .font(.callout)
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(info.capabilities) { cap in
                            HStack(spacing: 6) {
                                Image(systemName: cap.available ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(cap.available ? (cap.unverified ? Color.orange : Color.green) : Color.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(cap.title).font(.callout).foregroundStyle(cap.available ? .primary : .secondary)
                                    if let note = cap.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                                    else if cap.available && cap.unverified { Text("Unverified on hardware").font(.caption2).foregroundStyle(.orange) }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                Text("Select a connected controller to read its capabilities.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(session.selectedID ?? "")-\(session.canOperate)-\(session.diagnostics.firmware?.firmwareVersion ?? 0)") {
            info = await ControllerCapabilities.collect(session)
        }
        .accessibilityIdentifier("capabilitiesCard")
    }

    private var subtitle: String {
        guard let info else { return "Equivalent of tactile_controller_info" }
        return "\(info.model.displayName) · \(info.capabilities.filter(\.available).count) capabilities, all unverified on hardware"
    }
}

/// Headphone and microphone connection from the input report's status byte.
struct HeadsetStatusCard: View {
    var readings: LiveReadings

    var body: some View {
        LabCard(title: "Headset", symbol: "headphones", subtitle: "From input status byte 53; unverified on hardware.") {
            HStack(spacing: 24) {
                status("Headphones", symbol: "headphones", value: readings.input?.headphonesConnected)
                status("Microphone", symbol: "mic", value: readings.input?.micConnected)
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("headsetCard")
    }

    private func status(_ title: String, symbol: String, value: Bool?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: value == true ? "\(symbol).circle.fill" : "\(symbol).circle")
                .font(.title2)
                .foregroundStyle(value == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout)
                Text(value.map { $0 ? "Connected" : "Not connected" } ?? "Not reported").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Live haptics-stream statistics (the 0.3 `tactile_haptics_metrics` fields)
/// polled from the selected controller, plus the last speaker operation's counts.
struct StreamStatsView: View {
    var session: LabSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let c = session.selectedController
            let m = c?.hapticsMetrics()
            let period = HapticsFormat.reportPeriodSeconds * 1000
            let buffered = m?.bufferedMs ?? session.diagnostics.metrics["bufferedMs"]
            let send = m?.sendLatencyMeanUs ?? session.diagnostics.metrics["sendLatencyMeanUs"]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    pill(c?.hapticsRunning == true ? "Running" : "Stopped", on: c?.hapticsRunning == true)
                    pill(c?.hapticsSending == true ? "Sending" : "Idle", on: c?.hapticsSending == true)
                    if session.simulated { LabTag(text: "Simulated: no stream", symbol: "testtube.2", tint: .blue) }
                    Spacer(minLength: 0)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        stat("Buffered", buffered.map { String(format: "%.1f ms", $0) })
                        stat("Report period", String(format: "%.3f ms", period))
                        stat("Est. latency", buffered.map { String(format: "%.1f ms", $0 + period + (send ?? 0) / 1000) })
                    }
                    GridRow {
                        stat("Speaker reports", c.map { "\($0.speakerReportCount)" })
                        stat("Packets sent", session.diagnostics.metrics["speakerPacketsSent"].map { "\(Int($0))" })
                        stat("Oversized", session.diagnostics.metrics["speakerOversizedPackets"].map { "\(Int($0))" })
                    }
                }
                Text("Estimated latency = buffered + one report period + mean send time, as in tactile_haptics_metrics.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("streamStats")
    }

    private func pill(_ text: String, on: Bool) -> some View {
        Label(text, systemImage: on ? "circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(on ? .green : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassEffect(.regular, in: .capsule)
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.monospacedDigit())
        }
    }
}
