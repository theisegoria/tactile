import SwiftUI
import Tactile

struct DiagnosticsView: View {
    var session: LabSession
    @State private var filter = ""
    @State private var frozen: [RawReportRow]?
    @State private var label = "Baseline"
    @State private var before = 0
    @State private var after = 1
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)]
    private var filtered: [RawReportRow] {
        let rows = frozen ?? session.readings.raw
        guard !filter.isEmpty else { return rows }
        guard let id = UInt8(filter.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return [] }
        return rows.filter { $0.reportID == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabPageHeader(title: "Connection diagnostics",
                              subtitle: "Identity, firmware, calibration and the reports the controller is sending. Everything here is read-only.") {
                    Button("Refresh", systemImage: "arrow.clockwise") { session.refreshDiagnostics() }
                        .buttonStyle(.glass)
                        .disabled(!session.canOperate)
                }
                if let kind = LabEmptyState.kind(for: session) {
                    LabEmptyStateView(kind: kind, session: session)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
                identityCard
                LazyVGrid(columns: columns, spacing: 16) {
                    metricsCard
                    descriptorCard
                }
                snapshotsCard
                rawCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: session.selectedID) { _, _ in
            frozen = nil
            before = 0
            after = 1
        }
    }

    // MARK: Cards

    private var identityCard: some View {
        LabCard(title: "Controller", symbol: "gamecontroller", subtitle: session.selectedDevice?.displayName) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    Text("Identity").foregroundStyle(.secondary)
                    Text(session.selectedID ?? "None")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("diagnosticIdentity")
                        // Recreate the selectable text wrapper on a device
                        // change; macOS otherwise retains its old AX value.
                        .id(session.selectedID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabDetailRow(label: "Player", value: session.selectedID.flatMap(session.player(of:)).map { "Player \($0)" } ?? "None")
                LabDetailRow(label: "Firmware", value: session.diagnostics.firmware.map { "\($0.updateVersionString) · firmware \(String($0.firmwareVersion, radix: 16)) · hardware \(String($0.hardwareVersion, radix: 16))" } ?? "Not available")
                LabDetailRow(label: "GameController", value: session.diagnostics.gameController)
                LabDetailRow(label: "Calibration", value: session.diagnostics.calibration)
                LabDetailRow(label: "Input", value: "\(session.diagnostics.reportsReceived) reports · \(InputLabHealthReport.number(session.diagnostics.reportRate, 1)) Hz")
                LabDetailRow(label: "Potential writers", value: session.diagnostics.conflicts.isEmpty ? "None detected" : session.diagnostics.conflicts.joined(separator: ", "))
                LabDetailRow(label: "Virtual duplicates", value: "\(session.diagnostics.virtualTwins)")
            }
        }
    }

    private var metricsCard: some View {
        LabCard(title: "Haptics metrics", symbol: "waveform", subtitle: "Pump timing from the most recent haptics output.") {
            if session.diagnostics.metrics.isEmpty {
                Text("Start a haptics test to collect metrics.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    ForEach(session.diagnostics.metrics.keys.sorted(), id: \.self) { key in
                        GridRow {
                            Text(key).foregroundStyle(.secondary)
                            Text(session.diagnostics.metrics[key] ?? 0, format: .number.precision(.fractionLength(2))).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var descriptorCard: some View {
        LabCard(title: "Report descriptor", symbol: "list.bullet.rectangle", subtitle: "\(session.diagnostics.descriptor.count) declared reports") {
            if session.diagnostics.descriptor.isEmpty {
                Text("No descriptor read yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                DisclosureGroup("Report sizes") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(session.diagnostics.descriptor.enumerated()), id: \.offset) { _, report in
                            Text(report.description).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var snapshotsCard: some View {
        LabCard(title: "Feature snapshots", symbol: "camera.metering.matrix", subtitle: "Reads declared feature reports. No feature report is ever written.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Snapshot label", text: $label).textFieldStyle(.roundedBorder)
                    Button("Capture Snapshot") { session.captureSnapshot(label: label) }
                        .buttonStyle(.glass)
                        .disabled(!session.canOperate)
                }
                if session.snapshots.isEmpty {
                    Text("Capture a snapshot before and after a change to compare the bytes.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(session.snapshots.enumerated()), id: \.offset) { index, snapshot in
                    Label("\(index + 1). \(snapshot.label) · \(snapshot.reports.count) reports · \(snapshot.failures.count) read failures", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                if session.snapshots.count >= 2 {
                    Divider()
                    HStack { snapshotPicker("Before", selection: $before); snapshotPicker("After", selection: $after) }
                    if session.snapshots.indices.contains(before), session.snapshots.indices.contains(after) {
                        let differences = session.snapshots[before].diff(to: session.snapshots[after])
                        if differences.isEmpty { Text("No byte differences").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(differences.enumerated()), id: \.offset) { _, difference in
                            Text(difference.description).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var rawCard: some View {
        LabCard(title: "Raw reports", symbol: "terminal", subtitle: "Newest 120 input reports, refreshed twice a second.") {
            HStack(spacing: 8) {
                TextField("Filter report ID (hex)", text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 200)
                Button(frozen == nil ? "Pause Display" : "Resume Display") { frozen = frozen == nil ? session.readings.raw : nil }
                    .buttonStyle(.glass)
            }
        } content: {
            if filtered.isEmpty {
                Text(session.readings.raw.isEmpty ? "No reports received yet." : "No reports match this filter.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(filtered.reversed()) { row in Text("#\(row.id)  \(row.bytes.count) B  \(row.hex)").font(.caption.monospaced()).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 220)
            }
        }
    }

    private func snapshotPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) { ForEach(Array(session.snapshots.enumerated()), id: \.offset) { index, snapshot in Text(snapshot.label).tag(index) } }
    }
}
