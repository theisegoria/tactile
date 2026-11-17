import AppKit
import SwiftUI
import Tactile

/// Parameters of the selected event. Slider and colour changes apply live
/// and become one undo step when they pause.
struct ComposerInspector: View {
    @Bindable var model: ComposerModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if let event = model.selectedEvent {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(event.content.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelection(undoManager: undoManager) }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSelection(undoManager: undoManager) }
                        .accessibilityIdentifier("composerDeleteEvent")
                }
                .buttonStyle(.glass)
                timing(event)
                Divider()
                content(event)
            }
        } else {
            Label("Select an event to edit it. Double-click a lane to add one; drag to move, drag the right edge to resize, ⌫ deletes.",
                  systemImage: "cursorarrow.click")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timing(_ event: ComposerEvent) -> some View {
        HStack(spacing: 16) {
            seconds("Start", value: event.start) { e, v in e.start = v }
            seconds("Duration", value: event.duration) { e, v in e.duration = v }
            Text("Ends \(event.end, format: .number.precision(.fractionLength(3))) s").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func seconds(_ title: String, value: Double, set: @escaping (inout ComposerEvent, Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption)
            TextField(title, value: Binding(get: { value }, set: { v in
                guard v.isFinite else { return }
                model.updateSelected("Change \(title)", undoManager: undoManager) { set(&$0, v) }
            }), format: .number.precision(.fractionLength(0...3)))
            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
            Text("s").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ event: ComposerEvent) -> some View {
        switch event.content {
        case .parametric(let p):
            Picker("Effect", selection: binding(p.kind, name: "Change Effect", live: false) { e, v in
                guard case .parametric(var q) = e.content else { return }
                if q.kind.usesFrequency != v.usesFrequency || q.frequency == q.kind.defaultFrequency { q.frequency = v.defaultFrequency }
                q.kind = v; e.content = .parametric(q)
            }) {
                ForEach(ComposerEvent.Parametric.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ValueSlider(title: "Intensity", value: binding(Double(p.intensity), name: "Change Intensity") { e, v in
                guard case .parametric(var q) = e.content else { return }; q.intensity = Float(v); e.content = .parametric(q)
            }, range: 0...1, precision: 2)
            if p.kind.usesFrequency {
                ValueSlider(title: "Frequency (Hz)", value: binding(Double(p.frequency), name: "Change Frequency") { e, v in
                    guard case .parametric(var q) = e.content else { return }; q.frequency = Float(v); e.content = .parametric(q)
                }, range: 30...400)
            }
            if p.kind == .texture {
                ValueSlider(title: "Grains per second", value: binding(Double(p.grainRate), name: "Change Grain Rate") { e, v in
                    guard case .parametric(var q) = e.content else { return }; q.grainRate = Float(v); e.content = .parametric(q)
                }, range: 1...200)
            }
            if p.kind.isOneShot {
                ValueSlider(title: "Repeat every (s)", value: binding(p.repeatInterval, name: "Change Repeat") { e, v in
                    guard case .parametric(var q) = e.content else { return }; q.repeatInterval = v < 0.01 ? 0 : v; e.content = .parametric(q)
                }, range: 0...1, precision: 2)
                Text(p.repeatInterval < 0.01 ? "Plays once at the start of the event." : "Repeats while the event lasts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .audioClip(let clip):
            HStack {
                Image(systemName: "waveform")
                Text(clip.displayName).lineLimit(1).truncationMode(.middle)
                if ComposerClips.length(clip.path) == nil {
                    LabTag(text: "File missing or unreadable", symbol: "exclamationmark.triangle")
                }
                Spacer()
                Button("Replace…") {
                    guard let url = AudioFiles.choose() else { return }
                    model.updateSelected("Replace Clip", undoManager: undoManager) { e in
                        guard case .audioClip(var c) = e.content else { return }; c.path = url.path; e.content = .audioClip(c)
                    }
                }
            }
            ValueSlider(title: "Gain", value: binding(Double(clip.gain), name: "Change Gain") { e, v in
                guard case .audioClip(var c) = e.content else { return }; c.gain = Float(v); e.content = .audioClip(c)
            }, range: 0...4, precision: 2)
            ValueSlider(title: "Trim start (s)", value: binding(clip.trim, name: "Change Trim") { e, v in
                guard case .audioClip(var c) = e.content else { return }; c.trim = v; e.content = .audioClip(c)
            }, range: 0...max(1, clipLength(clip.path)), precision: 2)
        case .rumble(let r):
            ValueSlider(title: "Motor level", value: binding(Double(r.level), name: "Change Rumble") { e, v in
                e.content = .rumble(.init(level: Int(v.rounded())))
            }, range: 0...255)
            Text(model.selectedTrackKind() == .leftActuator
                 ? "Heavy motor: emulated at 55 Hz on both actuators, as the library does while audio haptics own them."
                 : "Light motor: emulated at 160 Hz on the right actuator.")
                .font(.caption).foregroundStyle(.secondary)
        case .trigger(let change):
            Picker("Trigger", selection: binding(change.side, name: "Change Trigger Side", live: false) { e, v in
                guard case .trigger(var c) = e.content else { return }; c.side = v; e.content = .trigger(c)
            }) {
                ForEach(ComposerEvent.TriggerChange.Side.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 260)
            TriggerParameterEditor(design: binding(change.design, name: "Change Trigger Effect") { e, v in
                guard case .trigger(var c) = e.content else { return }; c.design = v; e.content = .trigger(c)
            })
        case .lightbar(let key):
            ColorPicker("Colour", selection: binding(Color(red: Double(key.red) / 255, green: Double(key.green) / 255, blue: Double(key.blue) / 255), name: "Change Colour") { e, v in
                guard case .lightbar(var k) = e.content, let c = NSColor(v).usingColorSpace(.sRGB) else { return }
                k.red = Int((max(0, min(1, c.redComponent)) * 255).rounded())
                k.green = Int((max(0, min(1, c.greenComponent)) * 255).rounded())
                k.blue = Int((max(0, min(1, c.blueComponent)) * 255).rounded())
                e.content = .lightbar(k)
            }, supportsOpacity: false)
            ValueSlider(title: "Fade in (s)", value: binding(key.fade, name: "Change Fade") { e, v in
                guard case .lightbar(var k) = e.content else { return }; k.fade = v; e.content = .lightbar(k)
            }, range: 0...2, precision: 2)
            Text("Fades from the previous key. Preview only until composition playback is wired; Apply at Playhead sends the colour now.")
                .font(.caption).foregroundStyle(.secondary)
        case .unsupported(let type, _):
            Text("This event's type “\(type)” comes from a newer version. The library pattern format cannot hold it, so Save leaves it out.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func clipLength(_ path: String) -> Double {
        ComposerClips.length(path) ?? 0
    }

    private func binding<T>(_ value: T, name: String, live: Bool = true, set: @escaping (inout ComposerEvent, T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: { v in model.updateSelected(name, live: live, undoManager: undoManager) { set(&$0, v) } })
    }
}
