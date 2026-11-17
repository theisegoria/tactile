import SwiftUI
import Tactile

/// Input Lab: live analysis of the selected controller's sticks, triggers,
/// buttons and report timing, with record/replay and a health report export.
///
/// Mount as a detail screen: `InputLabView(session: session)`.
/// The analysis state lives in `InputLabStore.shared`, so it survives switching
/// tabs; pass another store for previews or tests.
struct InputLabView: View {
    var session: LabSession
    @State private var store: InputLabStore
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)]

    init(session: LabSession, store: InputLabStore? = nil) {
        self.session = session
        _store = State(initialValue: store ?? InputLabStore.shared)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = store.message { messageBar(message) }
                if store.source == .live, session.selectedDevice?.connected != true, !store.hasData {
                    LabEmptyStateView(kind: LabEmptyState.kind(for: session) ?? .noController, session: session) {
                        Button("Load Recording…", systemImage: "folder") { load() }
                    }
                    .frame(minHeight: 260)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    InputLabStickCard(title: "Left stick", position: store.current?.left, trail: store.trailLeft,
                                      drift: store.results.leftDrift, circularity: store.results.leftCircularity,
                                      fromRestWindow: store.results.driftFromRestWindow)
                    InputLabStickCard(title: "Right stick", position: store.current?.right, trail: store.trailRight,
                                      drift: store.results.rightDrift, circularity: store.results.rightCircularity,
                                      fromRestWindow: store.results.driftFromRestWindow)
                }
                InputLabPollingCard(stats: store.results.polling, reportTimes: store.reportTimes)
                LazyVGrid(columns: columns, spacing: 16) {
                    triggersCard
                    buttonsCard
                }
                Label("Sticks, triggers and buttons are sampled at the display rate (about 30 Hz); report intervals use each report's arrival time.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("inputLabView")
        .onChange(of: session.readings.input) { _, state in store.ingest(state) }
        .onChange(of: session.readings.raw.last?.id) { _, _ in store.ingestReports(session.readings.raw) }
        .onChange(of: session.selectedID) { _, _ in if store.source == .live { store.reset() } }
    }

    // MARK: Header

    private var header: some View {
        LabPageHeader(title: "Input Lab", subtitle: subtitle) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("Source", selection: Binding(get: { store.source }, set: { source in
                        if source == .live { store.goLive() } else if let recording = store.loadedRecording { store.replay(recording) } else { load() }
                    })) {
                        Text("Live").tag(InputLabStore.Source.live)
                        Text("Replay").tag(InputLabStore.Source.replay)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("inputLabSource")
                    if store.isRecording {
                        Button("Stop", systemImage: "stop.circle.fill") { stopRecording() }
                            .buttonStyle(.glassProminent).tint(.red)
                            .accessibilityIdentifier("inputLabStopRecording")
                    } else {
                        Button("Record", systemImage: "record.circle") { store.startRecording() }
                            .buttonStyle(.glass)
                            .disabled(store.source != .live || session.selectedDevice?.connected != true)
                            .accessibilityIdentifier("inputLabRecord")
                    }
                    Menu {
                        Button("Measure Rest (3 s)", systemImage: "scope") { store.measureRest() }
                            .disabled(store.source != .live)
                        Button("Reset Measurements", systemImage: "arrow.counterclockwise") { store.reset() }
                        Divider()
                        Button("Load Recording…", systemImage: "folder") { load() }
                        Button("Save Recording…", systemImage: "square.and.arrow.down") { save() }
                            .disabled(store.loadedRecording == nil)
                        Button("Replay Loaded Recording", systemImage: "play") { if let r = store.loadedRecording { store.replay(r) } }
                            .disabled(store.loadedRecording == nil)
                        Divider()
                        Button("Export Health Report…", systemImage: "heart.text.square") { exportReport() }
                            .disabled(!store.hasData)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button).buttonStyle(.glass).fixedSize()
                    .accessibilityIdentifier("inputLabActions")
                }
            }
        }
    }

    private var subtitle: String {
        switch store.source {
        case .replay:
            let name = store.loadedRecording?.deviceName ?? "recording"
            return "Replaying \(name) · \(Int(store.replayProgress * 100))%"
        case .live:
            if store.isRecording { return "Recording · \(store.recordedFrames) frames" }
            if store.measuringRest { return "Measuring rest · keep the sticks still" }
            guard let device = session.selectedDevice else { return "Select a controller, or load a recording to replay." }
            return "\(device.displayName) · \(store.frames.count) samples analysed"
        }
    }

    private func messageBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: store.isRecording ? "record.circle" : "info.circle").foregroundStyle(store.isRecording ? .red : .secondary)
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark") { store.clearMessage() }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("inputLabMessage")
    }

    // MARK: Cards

    private var triggersCard: some View {
        LabCard(title: "Trigger travel", symbol: "l2.rectangle.roundedtop", subtitle: "Press each trigger fully, then release.") {
            VStack(alignment: .leading, spacing: 14) {
                triggerRow("L2", value: store.current?.l2, range: store.results.l2)
                triggerRow("R2", value: store.current?.r2, range: store.results.r2)
            }
        }
    }

    private func triggerRow(_ name: String, value: UInt8?, range: TriggerRange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.callout.weight(.semibold))
                Spacer()
                Text(range.sampleCount == 0 ? "—" : "\(range.minimum)–\(range.maximum) · \(InputLabHealthReport.percent(range.travel))")
                    .font(.callout.monospacedDigit()).foregroundStyle(range.sampleCount > 0 && !range.fullTravel ? .orange : .secondary)
            }
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if range.sampleCount > 0 {
                        Capsule().fill(.cyan.opacity(0.25))
                            .frame(width: max(4, w * Double(Int(range.maximum) - Int(range.minimum)) / 255))
                            .offset(x: w * Double(range.minimum) / 255)
                    }
                    Capsule().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * Double(value ?? 0) / 255))
                }
            }
            .frame(height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) travel")
            .accessibilityValue("Current \(value ?? 0), range \(range.minimum) to \(range.maximum)")
        }
    }

    private var buttonsCard: some View {
        LabCard(title: "Button timing", symbol: "circle.grid.cross", subtitle: "Hold length and fastest repeat for each button pressed.") {
            if store.results.buttons.isEmpty {
                Text("Press any button to measure its timing.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Button"); Text("Presses"); Text("Mean hold"); Text("Fastest repeat")
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(store.results.buttons.prefix(12)) { timing in
                        GridRow {
                            Text(timing.name)
                            Text("\(timing.presses)").monospacedDigit()
                            Text("\(InputLabHealthReport.number(timing.meanHoldMs, 0)) ms").monospacedDigit()
                            Text(timing.fastestRepeatMs.map { "\(InputLabHealthReport.number($0, 0)) ms" } ?? "—").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func stopRecording() {
        guard let recording = store.stopRecording(device: session.selectedDevice) else { return }
        save(recording)
    }

    private func save(_ recording: InputLabRecording? = nil) {
        guard let recording = recording ?? store.loadedRecording else { return }
        let stamp = recording.createdAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        guard let url = InputLabFiles.chooseSaveURL(suggested: "Input recording \(stamp).json") else { return }
        do { try store.save(recording, to: url) } catch { session.showError(error) }
    }

    private func load() {
        guard let url = InputLabFiles.chooseOpenURL() else { return }
        do { store.replay(try store.load(from: url)) } catch { session.showError(error) }
    }

    private func exportReport() {
        guard let folder = InputLabFiles.chooseFolder(prompt: "Export Report", message: "Choose a folder for health.json and health.md.") else { return }
        do {
            let written = try InputLabStore.write(store.healthReport(session: session), to: folder)
            store.show("Exported the health report to \(written.path).")
        } catch { session.showError(error) }
    }
}

extension InputLabStore {
    /// The app-wide Input Lab store, so measurements survive tab switches.
    static let shared = InputLabStore()
}
