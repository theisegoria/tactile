import SwiftUI
import Tactile

struct DiagnosticsView: View {
    var session: LabSession
    @State private var filter = ""
    @State private var frozen: [RawReportRow]?
    @State private var label = "Baseline"
    @State private var before = 0
    @State private var after = 1
    private var filtered: [RawReportRow] {
        let rows = frozen ?? session.readings.raw
        guard !filter.isEmpty else { return rows }
        guard let id = UInt8(filter.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return [] }
        return rows.filter { $0.reportID == id }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Connection diagnostics").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { session.refreshDiagnostics() }.disabled(!session.canOperate)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    GridRow {
                        Text("Identity").foregroundStyle(.secondary)
                        Text(session.selectedID ?? "None")
                            .textSelection(.enabled)
                            .accessibilityIdentifier("diagnosticIdentity")
                            // Recreate the selectable text wrapper on a device
                            // change; macOS otherwise retains its old AX value.
                            .id(session.selectedID)
                    }
                    GridRow { Text("Firmware").foregroundStyle(.secondary); Text(session.diagnostics.firmware.map { "\($0.updateVersionString) · firmware \(String($0.firmwareVersion, radix: 16)) · hardware \(String($0.hardwareVersion, radix: 16))" } ?? "Not available") }
                    GridRow { Text("GameController").foregroundStyle(.secondary); Text(session.diagnostics.gameController) }
                    GridRow { Text("Calibration").foregroundStyle(.secondary); Text(session.diagnostics.calibration) }
                    GridRow { Text("Potential writers").foregroundStyle(.secondary); Text(session.diagnostics.conflicts.isEmpty ? "None detected" : session.diagnostics.conflicts.joined(separator: ", ")) }
                    GridRow { Text("Virtual duplicates").foregroundStyle(.secondary); Text("\(session.diagnostics.virtualTwins)") }
                }
                DisclosureGroup("Descriptor report sizes (\(session.diagnostics.descriptor.count))") {
                    ForEach(Array(session.diagnostics.descriptor.enumerated()), id: \.offset) { _, report in Text(report.description).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                }
                GroupBox("Haptics metrics") {
                    if session.diagnostics.metrics.isEmpty { Text("Start a haptics test to collect metrics.").foregroundStyle(.secondary).padding(8) }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading) {
                            ForEach(session.diagnostics.metrics.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(session.diagnostics.metrics[key] ?? 0, specifier: "%.2f")").font(.caption.monospaced())
                            }
                        }.padding(8)
                    }
                }
                GroupBox("Feature snapshots · read-only") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { TextField("Snapshot label", text: $label).textFieldStyle(.roundedBorder); Button("Capture Snapshot") { session.captureSnapshot(label: label) }.disabled(!session.canOperate) }
                        Text("Reads declared feature reports. No feature report is ever written.").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(session.snapshots.enumerated()), id: \.offset) { index, snapshot in
                            Text("\(index + 1). \(snapshot.label) · \(snapshot.reports.count) reports · \(snapshot.failures.count) read failures").font(.caption)
                        }
                        if session.snapshots.count >= 2 {
                            HStack { snapshotPicker("Before", selection: $before); snapshotPicker("After", selection: $after) }
                            if session.snapshots.indices.contains(before), session.snapshots.indices.contains(after) {
                                let differences = session.snapshots[before].diff(to: session.snapshots[after])
                                if differences.isEmpty { Text("No byte differences").font(.caption) }
                                ForEach(Array(differences.enumerated()), id: \.offset) { _, difference in Text(difference.description).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Raw reports · newest 120") {
                    VStack(spacing: 8) {
                        HStack {
                            TextField("Filter report ID (hex)", text: $filter).textFieldStyle(.roundedBorder).frame(width: 210)
                            Spacer()
                            Button(frozen == nil ? "Pause Display" : "Resume Display") { frozen = frozen == nil ? session.readings.raw : nil }
                        }
                        ScrollView(.horizontal) {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(filtered.reversed()) { row in Text("#\(row.id)  \(row.bytes.count) B  \(row.hex)").font(.caption.monospaced()).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 70, maxHeight: 220)
                    }.padding(8)
                }
            }.padding(20)
        }.onChange(of: session.selectedID) { _, _ in
            frozen = nil
            before = 0
            after = 1
        }
    }
    private func snapshotPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) { ForEach(Array(session.snapshots.enumerated()), id: \.offset) { index, snapshot in Text(snapshot.label).tag(index) } }
    }
}
