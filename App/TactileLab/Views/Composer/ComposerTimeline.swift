import AppKit
import SwiftUI
import Tactile

/// Track headers plus a horizontally scrolling lane area: ruler with a
/// scrubbable playhead, one lane per track, waveform under the actuator
/// lanes. Click a lane to move the playhead, double-click to add an event,
/// drag an event to move it, drag its trailing edge to resize.
struct ComposerTimeline: View {
    @Bindable var model: ComposerModel
    @Environment(\.undoManager) private var undoManager

    static let laneHeight: CGFloat = 58
    static let rulerHeight: CGFloat = 24
    static let headerWidth: CGFloat = 150

    private var visibleSeconds: Double { max(model.document.duration, model.document.contentEnd) + 1 }
    private var contentWidth: CGFloat { CGFloat(visibleSeconds * model.zoom) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.rulerHeight)
                ForEach(model.document.tracks) { track in
                    TrackHeader(model: model, track: track)
                        .frame(height: Self.laneHeight)
                }
            }
            .frame(width: Self.headerWidth)
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    Ruler(model: model, seconds: visibleSeconds)
                        .frame(width: contentWidth, height: Self.rulerHeight)
                    ForEach(model.document.tracks) { track in
                        Lane(model: model, track: track, width: contentWidth)
                            .frame(width: contentWidth, height: Self.laneHeight)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(.red)
                        .frame(width: 1.5)
                        .offset(x: CGFloat(model.playhead * model.zoom))
                        .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.visible)
        }
        .frame(height: Self.rulerHeight + Self.laneHeight * CGFloat(model.document.tracks.count))
        .onDeleteCommand { model.deleteSelection(undoManager: undoManager) }
        .accessibilityIdentifier("composerTimeline")
    }
}

private struct TrackHeader: View {
    @Bindable var model: ComposerModel
    let track: ComposerTrack
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: track.kind.symbol).foregroundStyle(ComposerPalette.color(track.kind))
            Text(track.kind.title).font(.callout).lineLimit(1)
            Spacer(minLength: 2)
            Button {
                model.edit(track.muted ? "Unmute Track" : "Mute Track", undoManager: undoManager) { doc in
                    if let i = doc.tracks.firstIndex(where: { $0.id == track.id }) { doc.tracks[i].muted.toggle() }
                }
            } label: {
                Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.wave.1")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(track.muted ? .orange : .secondary)
            .help(track.muted ? "Unmute this track" : "Mute this track in preview, playback and export")
        }
        .padding(.horizontal, 8)
        .opacity(track.muted ? 0.6 : 1)
    }
}

private struct Ruler: View {
    @Bindable var model: ComposerModel
    let seconds: Double

    var body: some View {
        Canvas { context, size in
            let step: Double = model.zoom >= 300 ? 0.1 : model.zoom >= 100 ? 0.25 : model.zoom >= 50 ? 0.5 : 1
            var t = 0.0
            while t <= seconds {
                let x = CGFloat(t * model.zoom)
                let major = abs(t.rounded() - t) < 0.0001
                var path = Path()
                path.move(to: CGPoint(x: x, y: major ? 8 : 15))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(major ? 0.7 : 0.35)), lineWidth: 1)
                if major {
                    context.draw(Text("\(Int(t)) s").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                }
                t += step
            }
        }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            model.playhead = model.snap(Double(drag.location.x) / model.zoom)
        })
        .help("Drag to move the playhead")
    }
}

private struct Lane: View {
    @Bindable var model: ComposerModel
    let track: ComposerTrack
    let width: CGFloat
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary.opacity(0.25))
            GridLines(zoom: model.zoom, grid: model.snapping ? model.grid : 0)
            if track.kind.isActuator {
                Waveform(samples: track.kind == .leftActuator ? model.mix.left : model.mix.right,
                         zoom: model.zoom, color: ComposerPalette.color(track.kind))
                    .opacity(track.muted ? 0.25 : 0.55)
            }
            ForEach(track.events) { event in
                EventBlock(model: model, event: event, kind: track.kind)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(.rect)
        .onTapGesture(count: 2) { location in
            model.addEvent(on: track.kind, at: Double(location.x) / model.zoom, undoManager: undoManager)
        }
        .onTapGesture { location in
            model.selection = nil
            model.playhead = model.snap(Double(location.x) / model.zoom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.kind.title) lane")
    }
}

private struct GridLines: View {
    let zoom: Double
    let grid: Double
    var body: some View {
        Canvas { context, size in
            let step = grid > 0 && grid * zoom >= 6 ? grid : 1
            var t = 0.0
            var path = Path()
            while CGFloat(t * zoom) <= size.width {
                let x = CGFloat(t * zoom)
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                t += step
            }
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Min/max envelope of the offline render, one bar per two points.
private struct Waveform: View {
    let samples: [Float]
    let zoom: Double
    let color: Color
    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let mid = size.height / 2
            let perPoint = ComposerMix.sampleRate / zoom
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let a = Int(Double(x) * perPoint), b = min(samples.count, Int(Double(x + 2) * perPoint))
                guard a < samples.count else { break }
                var lo: Float = 0, hi: Float = 0
                if b > a { for i in a..<b { lo = min(lo, samples[i]); hi = max(hi, samples[i]) } }
                if hi - lo > 0.001 {
                    path.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * mid * 0.9))
                    path.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * mid * 0.9))
                }
                x += 2
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

private struct EventBlock: View {
    @Bindable var model: ComposerModel
    let event: ComposerEvent
    let kind: ComposerTrack.Kind
    @Environment(\.undoManager) private var undoManager
    @State private var origin: (start: Double, duration: Double)?

    private var selected: Bool { model.selection == event.id }
    private var width: CGFloat { max(8, CGFloat(event.duration * model.zoom)) }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fill.opacity(selected ? 0.85 : 0.55).gradient)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.white.opacity(0.9) : fill.opacity(0.9), lineWidth: selected ? 2 : 1)
            }
            .overlay(alignment: .leading) {
                Label(event.content.title, systemImage: symbol)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(.white.opacity(selected ? 0.35 : 0.001))
                    .frame(width: 6)
                    .contentShape(.rect)
                    .gesture(resize)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            }
            .clipShape(.rect(cornerRadius: 8))
            .frame(width: width, height: ComposerTimeline.laneHeight - 14)
            .offset(x: CGFloat(event.start * model.zoom), y: 7)
            .gesture(move)
            .onTapGesture { model.selection = event.id }
            .contextMenu {
                Button("Duplicate") { model.selection = event.id; model.duplicateSelection(undoManager: undoManager) }
                Button("Delete", role: .destructive) { model.selection = event.id; model.deleteSelection(undoManager: undoManager) }
            }
            .accessibilityElement()
            .accessibilityLabel("\(event.content.title), \(String(format: "%.2f", event.start)) seconds, lasting \(String(format: "%.2f", event.duration))")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { model.selection = event.id }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                if origin == nil { origin = (event.start, event.duration); model.selection = event.id }
                guard let origin else { return }
                let start = model.snap(origin.start + Double(drag.translation.width) / model.zoom)
                let clamped = min(start, ComposerDocument.maximumDuration - origin.duration)
                model.drag { doc in
                    guard let (t, i) = doc.event(event.id) else { return }
                    doc.tracks[t].events[i].start = max(0, clamped)
                    doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, doc.tracks[t].events[i].end))
                }
            }
            .onEnded { _ in
                origin = nil
                model.endDrag("Move Event", undoManager: undoManager)
            }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                if origin == nil { origin = (event.start, event.duration); model.selection = event.id }
                guard let origin else { return }
                let end = model.snap(origin.start + origin.duration + Double(drag.translation.width) / model.zoom)
                let duration = max(model.snapping ? max(model.grid, 0.01) : 0.01, min(end, ComposerDocument.maximumDuration) - origin.start)
                model.drag { doc in
                    guard let (t, i) = doc.event(event.id) else { return }
                    doc.tracks[t].events[i].duration = duration
                    doc.duration = min(ComposerDocument.maximumDuration, max(doc.duration, doc.tracks[t].events[i].end))
                }
            }
            .onEnded { _ in
                origin = nil
                model.endDrag("Resize Event", undoManager: undoManager)
            }
    }

    private var fill: Color {
        if case .lightbar(let key) = event.content {
            return Color(red: Double(key.red) / 255, green: Double(key.green) / 255, blue: Double(key.blue) / 255)
        }
        return ComposerPalette.color(kind)
    }

    private var symbol: String {
        switch event.content {
        case .parametric(let p): p.kind == .impact ? "burst" : p.kind == .texture ? "circle.grid.3x3" : "waveform.path"
        case .audioClip: "waveform"
        case .rumble: "water.waves"
        case .trigger: "l2.button.angledtop.vertical.left"
        case .lightbar: "light.strip.2"
        case .unsupported: "questionmark"
        }
    }
}

enum ComposerPalette {
    static func color(_ kind: ComposerTrack.Kind) -> Color {
        switch kind {
        case .leftActuator: .cyan
        case .rightActuator: .mint
        case .triggers: .orange
        case .lightbar: .purple
        }
    }
}
