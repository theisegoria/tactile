import SwiftUI
import Tactile

/// Haptic Composer: a timeline of actuator, trigger and lightbar events with
/// an offline waveform preview, undo, `.tactilepattern` files and Swift export.
///
/// Play renders the actuator tracks (parametric, audio clips, emulated rumble)
/// to a 3 kHz stereo WAV and sends it through the session's file-haptics
/// operation, so simulation sends nothing and Stop All ends it. Trigger and
/// lightbar tracks preview on screen during playback; "Apply at Playhead"
/// sends their state at the playhead. Sending them on schedule during
/// playback needs the `composition` command (ControllerOperations+Composer).
struct ComposerView: View {
    @Bindable var session: LabSession
    @State private var model = ComposerModel()
    @State private var showCode = false
    @State private var renaming = false
    @State private var newName = ""
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabScreenHeader(title: "Haptic Composer",
                                detail: "Lay out actuator haptics, audio clips, rumble, trigger effects and lightbar colours on a timeline. The waveform is rendered offline, with no controller needed.") {
                    fileActions
                }
                NoControllerNotice(session: session)
                transport
                LabCard(title: model.document.name + (model.dirty ? " — Edited" : ""), symbol: "timeline.selection",
                        subtitle: "\(model.document.tracks.flatMap(\.events).count) events · \(String(format: "%.2f", model.document.contentEnd)) s of content") {
                    addMenu
                } content: {
                    ComposerTimeline(model: model)
                }
                HStack(alignment: .top, spacing: 16) {
                    LabCard(title: "Event", symbol: "slider.horizontal.3") {
                        ComposerInspector(model: model)
                    }
                    .frame(minWidth: 300, maxWidth: .infinity)
                    preview.frame(minWidth: 220, maxWidth: 300)
                }
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showCode) {
            CodeExportSheet(title: "Copy as Code — \(model.document.name)",
                            code: { _ in ComposerExporters.all[0].code(for: model.document) })
        }
        .alert("Rename Pattern", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.rename(newName, undoManager: undoManager) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: session.activeOperation) { _, operation in
            if operation == nil, model.playing { model.stopPlayhead() }
        }
        .onDisappear { model.stopPlayhead() }
        .accessibilityIdentifier("composerView")
    }

    // MARK: Header actions

    private var fileActions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("New Pattern") { model.newDocument(undoManager: undoManager) }
                    Button("Open…") { run { try model.open(undoManager: undoManager) } }
                    Divider()
                    Button("Save") { run { try model.save() } }
                    Button("Save As…") { run { try model.save(as: true) } }
                    Divider()
                    Button("Rename…") { newName = model.document.name; renaming = true }
                } label: {
                    Label("File", systemImage: "doc")
                }
                .menuStyle(.button).buttonStyle(.glass).fixedSize()
                Button("Copy as Code", systemImage: "chevron.left.forwardslash.chevron.right") { showCode = true }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("composerCopyCode")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(ComposerTrack.Kind.allCases, id: \.self) { kind in
                Button("\(kind.isActuator ? "Haptic effect" : kind == .triggers ? "Trigger effect" : "Colour key") on \(kind.title)") {
                    model.addEvent(on: kind, at: model.playhead, undoManager: undoManager)
                }
            }
            Divider()
            Button("Audio Clip on Left Actuator…") { model.addAudioClip(on: .leftActuator, undoManager: undoManager) }
            Button("Audio Clip on Right Actuator…") { model.addAudioClip(on: .rightActuator, undoManager: undoManager) }
            Divider()
            Button("Rumble on Left (heavy) Motor") { model.addRumble(on: .leftActuator, undoManager: undoManager) }
            Button("Rumble on Right (light) Motor") { model.addRumble(on: .rightActuator, undoManager: undoManager) }
        } label: {
            Label("Add at Playhead", systemImage: "plus")
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .accessibilityIdentifier("composerAdd")
    }

    // MARK: Transport

    private var transport: some View {
        LabCard(title: "Transport", symbol: "play.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if model.playing {
                        Button("Stop", systemImage: "stop.fill") { stop() }
                            .buttonStyle(.glassProminent).tint(.red)
                    } else {
                        Button("Play", systemImage: "play.fill") { play() }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.canOperate || model.document.contentEnd <= 0)
                            .help("Render the actuator tracks and play them on the selected controller")
                            .accessibilityIdentifier("composerPlay")
                    }
                    Button("Preview", systemImage: "eye") { model.startPlayhead(length: model.playLength) }
                        .buttonStyle(.glass)
                        .disabled(model.playing)
                        .help("Run the playhead without sending anything")
                    Button("Apply at Playhead", systemImage: "scope") { applyAtPlayhead() }
                        .buttonStyle(.glass)
                        .disabled(!session.canOperate)
                        .help("Send the trigger effects and lightbar colour in force at the playhead, for the test length")
                    Spacer(minLength: 8)
                    Text(String(format: "%06.3f s", model.playhead)).font(.title3.monospacedDigit())
                        .accessibilityLabel("Playhead \(String(format: "%.2f", model.playhead)) seconds")
                }
                HStack(spacing: 14) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                        .disabled(!(undoManager?.canUndo ?? false))
                    Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                        .disabled(!(undoManager?.canRedo ?? false))
                    Divider().frame(height: 18)
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $model.zoom, in: 40...maxZoom).frame(minWidth: 80, maxWidth: 180)
                        .accessibilityLabel("Zoom")
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                    Divider().frame(height: 18)
                    Toggle("Snap", isOn: $model.snapping).toggleStyle(.switch).controlSize(.small)
                    Picker("Grid", selection: $model.grid) {
                        Text("10 ms").tag(0.01); Text("50 ms").tag(0.05); Text("100 ms").tag(0.1); Text("250 ms").tag(0.25)
                    }
                    .labelsHidden().fixedSize().disabled(!model.snapping)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var maxZoom: Double { max(41, min(600, 24_000 / max(1, model.document.duration + 1))) }

    // MARK: Preview

    private var preview: some View {
        let lightbar = ComposerRenderer.lightbar(in: model.document, at: model.playhead)
        let triggers = ComposerRenderer.triggers(in: model.document, at: model.playhead)
        return LabCard(title: "At the Playhead", symbol: "eye") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(lightbar.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) } ?? Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 18)
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                    Text(lightbar == nil ? "Lightbar unchanged" : "Lightbar").font(.callout)
                }
                LabeledContent("L2", value: triggers.left?.summary ?? "—")
                LabeledContent("R2", value: triggers.right?.summary ?? "—")
                Divider()
                if model.mix.clipped > 0 {
                    Label("\(model.mix.clipped) samples clip at full scale; lower intensities or gain.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(model.mix.isSilent ? "The actuator tracks are silent." : "Play sends the actuator mix (3 kHz, the waveform above). Felt result unverified on hardware.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }

    // MARK: Actions

    private func play() {
        run {
            let plan = try model.playbackPlan()
            let length = plan.length
            // The session holds one test length for every operation; play for
            // the pattern's length, then put the user's setting back.
            let previous = session.duration
            session.duration = length
            session.perform(.composition(plan), name: "Composer", settings: "pattern=\(model.document.name); length=\(String(format: "%.3f", length))s; actuator mix 3 kHz stereo WAV; \(plan.outputKeys.count) trigger/lightbar keys")
            session.duration = previous
            if session.activeOperation == "Composer" { model.startPlayhead(length: length) }
        }
    }

    private func stop() {
        model.stopPlayhead()
        Task { await session.stopAll() }
    }

    private func applyAtPlayhead() {
        let t = ComposerRenderer.triggers(in: model.document, at: model.playhead)
        do {
            var state = OutputState()
            state.leftTrigger = try (t.left ?? .off).effect()
            state.rightTrigger = try (t.right ?? .off).effect()
            state.lightbar = ComposerRenderer.lightbar(in: model.document, at: model.playhead)?.color
            session.perform(.output(state), name: "Composer state at playhead",
                            settings: "t=\(String(format: "%.3f", model.playhead))s; L2=\(t.left?.summary ?? "off"); R2=\(t.right?.summary ?? "off")")
        } catch { session.showError(error) }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { session.showError(error) }
    }
}
