import AppKit
import Foundation
import Observation
import Tactile

/// Editing state for the Composer: the document, selection, view settings and
/// undo. Every document change goes through `edit`, which registers the prior
/// document with the window's UndoManager (whole-value snapshots; documents
/// are small).
@MainActor @Observable
final class ComposerModel {
    private(set) var document = ComposerDocument.example
    private(set) var mix = ComposerMix()
    var selection: UUID?
    var playhead = 0.0
    /// Points per second on the timeline.
    var zoom = 160.0
    var snapping = true
    var grid = 0.05
    private(set) var fileURL: URL?
    private(set) var dirty = false
    private(set) var playing = false
    private var liveCommit: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    /// The document when a drag began; one undo step covers the whole drag.
    private var dragOrigin: ComposerDocument?

    init() { rerender() }

    // MARK: Editing

    func edit(_ name: String, undoManager: UndoManager?, _ change: (inout ComposerDocument) -> Void) {
        let before = document
        var after = document
        change(&after)
        guard after != before else { return }
        commit(after, replacing: before, name: name, undoManager: undoManager)
    }

    /// Live changes during a drag; call `endDrag` to record one undo step.
    func drag(_ change: (inout ComposerDocument) -> Void) {
        if dragOrigin == nil { dragOrigin = document }
        change(&document)
    }

    /// Continuous edits (sliders, colour wells): applied live, recorded as
    /// one undo step once they pause for 0.4 s.
    func liveEdit(_ name: String, undoManager: UndoManager?, _ change: (inout ComposerDocument) -> Void) {
        drag(change)
        liveCommit?.cancel()
        liveCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.endDrag(name, undoManager: undoManager)
        }
    }

    func endDrag(_ name: String, undoManager: UndoManager?) {
        liveCommit?.cancel(); liveCommit = nil
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        let after = document
        document = origin
        guard after != origin else { return }
        commit(after, replacing: origin, name: name, undoManager: undoManager)
    }

    private func commit(_ after: ComposerDocument, replacing before: ComposerDocument, name: String, undoManager: UndoManager?) {
        document = after
        dirty = true
        rerender()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.commit(before, replacing: after, name: name, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(name)
    }

    func snap(_ t: Double) -> Double {
        let clamped = max(0, min(ComposerDocument.maximumDuration, t))
        guard snapping, grid > 0 else { return clamped }
        return (clamped / grid).rounded() * grid
    }

    func addEvent(on kind: ComposerTrack.Kind, at time: Double, undoManager: UndoManager?) {
        let start = snap(time)
        let content: ComposerEvent.Content = switch kind {
        case .leftActuator, .rightActuator: .parametric(.init(kind: .tone, intensity: 0.5, frequency: 160))
        case .triggers: .trigger(.init(side: .right, design: TriggerDesign.presets[0].design))
        case .lightbar: .lightbar(.init())
        }
        let duration = kind.isActuator ? 0.3 : 0.5
        let event = ComposerEvent(start: start, duration: duration, content: content)
        edit("Add Event", undoManager: undoManager) { doc in
            guard let t = doc.tracks.firstIndex(where: { $0.kind == kind }) else { return }
            doc.tracks[t].events.append(event)
            doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, event.end))
        }
        selection = event.id
    }

    func addAudioClip(on kind: ComposerTrack.Kind, undoManager: UndoManager?) {
        guard kind.isActuator, let url = AudioFiles.choose() else { return }
        var length = 1.0
        if let samples = ComposerRenderer.decodedClip(url.path) { length = max(0.05, Double(samples.count) / ComposerMix.sampleRate) }
        let start = snap(playhead)
        let event = ComposerEvent(start: start, duration: min(length, ComposerDocument.maximumDuration - start),
                                  content: .audioClip(.init(path: url.path)))
        edit("Add Audio Clip", undoManager: undoManager) { doc in
            guard let t = doc.tracks.firstIndex(where: { $0.kind == kind }) else { return }
            doc.tracks[t].events.append(event)
            doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, event.end))
        }
        selection = event.id
    }

    func addRumble(on kind: ComposerTrack.Kind, undoManager: UndoManager?) {
        guard kind.isActuator else { return }
        let event = ComposerEvent(start: snap(playhead), duration: 0.3, content: .rumble(.init()))
        edit("Add Rumble", undoManager: undoManager) { doc in
            guard let t = doc.tracks.firstIndex(where: { $0.kind == kind }) else { return }
            doc.tracks[t].events.append(event)
            doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, event.end))
        }
        selection = event.id
    }

    func deleteSelection(undoManager: UndoManager?) {
        guard let id = selection else { return }
        edit("Delete Event", undoManager: undoManager) { doc in
            guard let (t, i) = doc.event(id) else { return }
            doc.tracks[t].events.remove(at: i)
        }
        selection = nil
    }

    func duplicateSelection(undoManager: UndoManager?) {
        guard let id = selection, let (t, i) = document.event(id) else { return }
        var copy = document.tracks[t].events[i]
        copy.id = UUID()
        copy.start = min(ComposerDocument.maximumDuration - copy.duration, copy.end)
        edit("Duplicate Event", undoManager: undoManager) { doc in
            doc.tracks[t].events.append(copy)
            doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, copy.end))
        }
        selection = copy.id
    }

    var selectedEvent: ComposerEvent? {
        guard let id = selection, let (t, i) = document.event(id) else { return nil }
        return document.tracks[t].events[i]
    }

    func selectedTrackKind() -> ComposerTrack.Kind? {
        guard let id = selection, let (t, _) = document.event(id) else { return nil }
        return document.tracks[t].kind
    }

    func updateSelected(_ name: String, live: Bool = false, undoManager: UndoManager?, _ change: @escaping (inout ComposerEvent) -> Void) {
        guard let id = selection else { return }
        let apply: (inout ComposerDocument) -> Void = { doc in
            guard let (t, i) = doc.event(id) else { return }
            change(&doc.tracks[t].events[i])
            var e = doc.tracks[t].events[i]
            e.start = max(0, min(ComposerDocument.maximumDuration - 0.01, e.start))
            e.duration = max(0.01, min(ComposerDocument.maximumDuration - e.start, e.duration))
            doc.tracks[t].events[i] = e
            doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, e.end))
        }
        if live { liveEdit(name, undoManager: undoManager, apply) } else { edit(name, undoManager: undoManager, apply) }
    }

    func rerender() {
        mix = ComposerRenderer.render(document)
    }

    // MARK: Files

    func newDocument(undoManager: UndoManager?) {
        stopPlayhead()
        undoManager?.removeAllActions()
        document = ComposerDocument()
        fileURL = nil; dirty = false; selection = nil; playhead = 0
        rerender()
    }

    func open(undoManager: UndoManager?) throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tactilePattern, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Open a Tactile pattern (.\(ComposerDocument.fileExtension))."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = try ComposerDocument.decode(Data(contentsOf: url))
        stopPlayhead()
        undoManager?.removeAllActions()
        document = doc
        fileURL = url; dirty = false; selection = nil; playhead = 0
        rerender()
    }

    func save(as forceAsk: Bool = false) throws {
        var url = fileURL
        if url == nil || forceAsk {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.tactilePattern]
            panel.nameFieldStringValue = "\(document.name).\(ComposerDocument.fileExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard let url else { return }
        try document.encoded().write(to: url, options: .atomic)
        fileURL = url; dirty = false
    }

    func rename(_ name: String, undoManager: UndoManager?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit("Rename Pattern", undoManager: undoManager) { $0.name = trimmed }
    }

    // MARK: Playback

    /// Length of a play request: the content plus a short tail.
    var playLength: Double { min(ComposerDocument.maximumDuration, max(0.1, document.contentEnd + 0.25)) }

    /// Renders the actuator mix to a temporary WAV for the session's
    /// file-haptics operation.
    func renderPlaybackFile() throws -> URL {
        let mix = ComposerRenderer.render(document, length: playLength)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TactileComposer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(ComposerExporters.fileSafe(document.name)).wav")
        try ComposerRenderer.writeWAV(mix, to: url)
        return url
    }

    /// The full plan (actuator mix plus timed trigger/lightbar changes) for a
    /// `composition` command once the main session wires it.
    func playbackPlan() throws -> ComposerPlaybackPlan {
        ComposerPlaybackPlan(actuatorFile: try renderPlaybackFile(),
                             outputKeys: ComposerRenderer.outputKeys(for: document).map { ComposerOutputKey(time: $0.time, state: $0.state) },
                             length: playLength)
    }

    /// Moves the playhead in real time; the output itself is the session's.
    func startPlayhead(length: Double) {
        playTask?.cancel()
        playing = true
        playhead = 0
        let started = Date()
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= length { self.playhead = length; break }
                self.playhead = elapsed
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.playing = false
        }
    }

    func stopPlayhead() {
        playTask?.cancel(); playTask = nil
        playing = false
    }
}

extension ComposerExporters {
    static func fileSafe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Pattern" : cleaned
    }
}
