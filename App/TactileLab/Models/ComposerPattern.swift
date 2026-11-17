import AVFAudio
import Foundation
import Synchronization
import Tactile

// The Composer edits a `ComposerDocument` (events with a start and a length,
// one lane per output) and stores, previews and plays the library's
// `HapticPattern` (`.tactilepattern`, schema 1). This file converts between
// the two:
//
// * Actuator tracks become `effect`, `audio` and `rumble` events. A repeating
//   one-shot becomes one effect event per onset, with ids "<uuid>#r<k>", and
//   is regrouped on load.
// * Trigger lanes become the library's instantaneous trigger changes: the
//   effect in force per side at every event boundary (Off after an event
//   ends), so playback matches the timeline exactly. On load each change
//   lasts until the next change on that side; matching left/right spans
//   merge into one "Both" event.
// * Lightbar keys become colour keys; a fade becomes a step key holding the
//   previous colour (id "<uuid>#fade") plus a linear key where the fade
//   arrives, and is regrouped on load.
//
// Files Tactile Lab wrote round-trip: document → pattern → document →
// pattern gives the same pattern. Patterns from elsewhere load with these
// approximations: a linear lightbar key without the fade marker loads as a
// step key, an effect or rumble on both sides loads as one event per lane,
// and a muted track that is not one of the four Composer lanes is unmuted.

extension ComposerDocument {
    static let repeatMarker = "#r"
    static let fadeMarker = "#fade"

    /// The library pattern this document plays and saves.
    var pattern: HapticPattern {
        let tracks = self.tracks.map { track -> HapticPatternTrack in
            let events: [HapticPatternEvent] = switch track.kind {
            case .leftActuator, .rightActuator: actuatorEvents(track)
            case .triggers: triggerEvents(track)
            case .lightbar: lightbarEvents(track)
            }
            return HapticPatternTrack(id: track.kind.rawValue, name: track.kind.title, isMuted: track.muted, events: events)
        }
        return HapticPattern(name: name, tracks: tracks)
    }

    /// Events of a kind the library format cannot hold (kept from older app files); not saved.
    var unsupportedEventCount: Int {
        tracks.flatMap(\.events).filter { if case .unsupported = $0.content { true } else { false } }.count
    }

    private func actuatorEvents(_ track: ComposerTrack) -> [HapticPatternEvent] {
        let side = track.kind.side ?? .both
        var out: [HapticPatternEvent] = []
        for e in track.events.sorted(by: { $0.start < $1.start }) {
            let id = e.id.uuidString
            switch e.content {
            case .parametric(let p):
                if p.kind.isOneShot, p.repeatInterval > 0.005 {
                    var k = 0
                    var onset = e.start
                    while onset < e.end - 1e-9 {
                        out.append(HapticPatternEvent(id: id + Self.repeatMarker + String(k), time: onset, .effect(p.effect(duration: 0), side: side)))
                        k += 1
                        onset = e.start + Double(k) * p.repeatInterval
                    }
                } else {
                    out.append(HapticPatternEvent(id: id, time: e.start, .effect(p.effect(duration: e.duration), side: side)))
                }
            case .audioClip(let clip):
                let audio = HapticAudioClip(path: clip.path, gain: clip.gain, trimStart: max(0, clip.trim),
                                            trimEnd: max(0, clip.trim) + e.duration, side: clip.side ?? side)
                out.append(HapticPatternEvent(id: id, time: e.start, .audio(audio)))
            case .rumble(let r):
                let level = UInt8(clamping: r.level)
                let rumble = track.kind == .leftActuator ? Rumble(left: level, right: 0) : Rumble(left: 0, right: level)
                out.append(HapticPatternEvent(id: id, time: e.start, .rumble(rumble, duration: e.duration)))
            case .trigger, .lightbar, .unsupported:
                break
            }
        }
        return out
    }

    private func triggerEvents(_ track: ComposerTrack) -> [HapticPatternEvent] {
        var out: [HapticPatternEvent] = []
        for side in TriggerSide.allCases {
            let spans = track.events.filter {
                if case .trigger(let change) = $0.content { change.side.covers(side) } else { false }
            }
            let boundaries = Set(spans.flatMap { [$0.start, $0.end] }).sorted()
            // Controllers start each operation neutral, so a leading Off is not written.
            var last: TriggerEffectSpec = .off
            var lastEffectID = ""
            for t in boundaries {
                let active = Self.activeTrigger(in: track, side: side, at: t)
                let spec = active?.design.spec ?? .off
                guard spec != last else { continue }
                last = spec
                let id: String
                if spec == .off { id = "\(lastEffectID)-\(side.rawValue)-off" }
                else { lastEffectID = active!.id.uuidString; id = "\(lastEffectID)-\(side.rawValue)" }
                out.append(HapticPatternEvent(id: id, time: t, .trigger(side, spec)))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    private func lightbarEvents(_ track: ComposerTrack) -> [HapticPatternEvent] {
        var out: [HapticPatternEvent] = []
        var previous: LightbarColor?
        for e in track.events.sorted(by: { $0.start < $1.start }) {
            guard case .lightbar(let key) = e.content else { continue }
            let id = e.id.uuidString
            if key.fade > 0, let previous {
                out.append(HapticPatternEvent(id: id + Self.fadeMarker, time: e.start, .lightbar(previous, interpolation: .step)))
                out.append(HapticPatternEvent(id: id, time: e.start + min(key.fade, e.duration), .lightbar(key.color, interpolation: .linear)))
            } else {
                out.append(HapticPatternEvent(id: id, time: e.start, .lightbar(key.color, interpolation: .step)))
            }
            previous = key.color
        }
        return out
    }

    // MARK: State at a time (timeline semantics)

    /// The trigger event in force on `side` at `time`: the latest-starting
    /// event covering it.
    static func activeTrigger(in track: ComposerTrack, side: TriggerSide, at time: Double) -> (id: UUID, design: TriggerDesign)? {
        guard !track.muted else { return nil }
        var found: (UUID, TriggerDesign)?
        for event in track.events.sorted(by: { $0.start < $1.start }) where event.start <= time && time < event.end {
            if case .trigger(let change) = event.content, change.side.covers(side) { found = (event.id, change.design) }
        }
        return found.map { (id: $0.0, design: $0.1) }
    }

    /// The trigger effects in force at `time`, per side (nil = no event).
    func triggers(at time: Double) -> (left: TriggerDesign?, right: TriggerDesign?) {
        guard let track = track(.triggers) else { return (nil, nil) }
        return (Self.activeTrigger(in: track, side: .left, at: time)?.design, Self.activeTrigger(in: track, side: .right, at: time)?.design)
    }

    /// The lightbar colour at `time`, with fades applied (nil = unchanged).
    func lightbar(at time: Double) -> ComposerEvent.LightbarKey? {
        guard let track = track(.lightbar), !track.muted else { return nil }
        let keys = track.events.sorted { $0.start < $1.start }
        guard let index = keys.lastIndex(where: { $0.start <= time && time < $0.end }),
              case .lightbar(let key) = keys[index].content else { return nil }
        guard key.fade > 0, time - keys[index].start < key.fade, index > 0,
              case .lightbar(let previous) = keys[index - 1].content else { return key }
        let t = (time - keys[index].start) / key.fade
        func mix(_ a: Int, _ b: Int) -> Int { Int(Double(a) + (Double(b) - Double(a)) * t) }
        return ComposerEvent.LightbarKey(red: mix(previous.red, key.red), green: mix(previous.green, key.green), blue: mix(previous.blue, key.blue))
    }
}

extension ComposerEvent.TriggerChange.Side {
    func covers(_ side: TriggerSide) -> Bool { self == .both || rawValue == side.rawValue }
}

// MARK: Pattern → document

extension ComposerDocument {
    /// The editable document for a library pattern. Relative clip paths
    /// resolve against `clipBase` (the pattern file's folder) and are stored
    /// absolute. `notes` explains anything that could not be kept as is.
    init(pattern: HapticPattern, clipBase: URL? = nil, notes: inout [String]) {
        self.init(name: pattern.name)
        var used = Set<UUID>()
        func uuid(_ id: String) -> UUID {
            let base = String(id.prefix(36))
            if let u = UUID(uuidString: base), !used.contains(u) { used.insert(u); return u }
            let fresh = UUID(); used.insert(fresh); return fresh
        }
        func index(_ kind: ComposerTrack.Kind) -> Int { tracks.firstIndex { $0.kind == kind }! }

        // Muting carries over for the four Composer lanes.
        for track in pattern.tracks {
            if let kind = ComposerTrack.Kind(rawValue: track.id) { tracks[index(kind)].muted = track.isMuted }
            else if track.isMuted, !track.events.isEmpty { notes.append("Track \u{201C}\(track.name)\u{201D} was muted in the file and is unmuted here.") }
        }
        let all = pattern.tracks.flatMap(\.events)
        let end = max(pattern.duration, all.map(\.time).max() ?? 0)

        // Actuators: effects (regrouping repeats), audio clips, rumble.
        var repeats: [String: [(time: Double, effect: HapticEffect, lane: ComposerTrack.Kind)]] = [:]
        var repeatOrder: [String] = []
        for e in all {
            switch e.action {
            case let .effect(effect, side):
                for lane in Self.lanes(for: side) {
                    if let r = e.id.range(of: Self.repeatMarker, options: .backwards), Int(e.id[r.upperBound...]) != nil {
                        let key = String(e.id[..<r.lowerBound]) + "|" + lane.rawValue
                        if repeats[key] == nil { repeatOrder.append(key) }
                        repeats[key, default: []].append((e.time, effect, lane))
                    } else {
                        let (p, d) = Self.parametric(effect)
                        tracks[index(lane)].events.append(ComposerEvent(id: uuid(e.id), start: e.time, duration: d, content: .parametric(p)))
                    }
                }
            case let .audio(clip):
                let lane: ComposerTrack.Kind = clip.side == .right ? .rightActuator : .leftActuator
                var path = clip.path
                if !path.hasPrefix("/"), let clipBase { path = clipBase.appendingPathComponent(path).path }
                let length = clip.trimEnd.map { $0 - clip.trimStart } ?? ((ComposerClips.length(path) ?? 1) - clip.trimStart)
                tracks[index(lane)].events.append(ComposerEvent(id: uuid(e.id), start: e.time, duration: max(0.01, length),
                                                                content: .audioClip(.init(path: path, gain: clip.gain, trim: clip.trimStart,
                                                                                          side: clip.side == .both ? .both : nil))))
            case let .rumble(r, d):
                var duration = d
                if duration <= 0 {
                    let next = all.compactMap { x -> Double? in
                        if case .rumble = x.action, x.time > e.time { x.time } else { nil }
                    }.min()
                    duration = (next ?? max(end, e.time + 0.5)) - e.time
                }
                if r.left > 0 {
                    tracks[index(.leftActuator)].events.append(ComposerEvent(id: uuid(e.id), start: e.time, duration: max(0.01, duration), content: .rumble(.init(level: Int(r.left)))))
                }
                if r.right > 0 {
                    tracks[index(.rightActuator)].events.append(ComposerEvent(id: uuid(e.id), start: e.time, duration: max(0.01, duration), content: .rumble(.init(level: Int(r.right)))))
                }
            case .trigger, .lightbar:
                break
            }
        }
        for key in repeatOrder {
            let onsets = repeats[key]!.sorted { $0.time < $1.time }
            let base = String(key[..<key.lastIndex(of: "|")!])
            // Microsecond rounding undoes the float error of start + k × interval.
            let interval = onsets.count > 1 ? ((onsets[1].time - onsets[0].time) * 1e6).rounded() / 1e6 : 0
            let uniform = onsets.count > 1 && interval > 0.005 && onsets.allSatisfy { $0.effect == onsets[0].effect }
                && onsets.indices.allSatisfy { abs(onsets[$0].time - (onsets[0].time + Double($0) * interval)) < 1e-6 }
            if uniform {
                var (p, _) = Self.parametric(onsets[0].effect)
                p.repeatInterval = interval
                tracks[index(onsets[0].lane)].events.append(ComposerEvent(id: uuid(base), start: onsets[0].time,
                                                                         duration: Double(onsets.count) * interval, content: .parametric(p)))
            } else {
                for o in onsets {
                    let (p, d) = Self.parametric(o.effect)
                    tracks[index(o.lane)].events.append(ComposerEvent(id: uuid(base), start: o.time, duration: d, content: .parametric(p)))
                }
            }
        }

        // Triggers: spans between changes per side, merged into Both where equal.
        var spans: [TriggerSide: [(start: Double, end: Double, spec: TriggerEffectSpec, id: String)]] = [:]
        for side in TriggerSide.allCases {
            let changes = all.compactMap { e -> (Double, TriggerEffectSpec, String)? in
                if case let .trigger(s, spec) = e.action, s == side { (e.time, spec, e.id) } else { nil }
            }.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
            for (i, c) in changes.enumerated() where c.1 != .off {
                let stop = i + 1 < changes.count ? changes[i + 1].0 : max(end, c.0 + 0.5)
                guard stop > c.0 else { continue }
                spans[side, default: []].append((c.0, stop, c.1, c.2))
            }
        }
        var rights = spans[.right] ?? []
        for l in spans[.left] ?? [] {
            var side = ComposerEvent.TriggerChange.Side.left
            if let match = rights.firstIndex(where: { abs($0.start - l.start) < 1e-9 && abs($0.end - l.end) < 1e-9 && $0.spec == l.spec }) {
                rights.remove(at: match); side = .both
            }
            tracks[index(.triggers)].events.append(ComposerEvent(id: uuid(l.id), start: l.start, duration: max(0.01, l.end - l.start),
                                                                content: .trigger(.init(side: side, design: TriggerDesign(spec: l.spec)))))
        }
        for r in rights {
            tracks[index(.triggers)].events.append(ComposerEvent(id: uuid(r.id), start: r.start, duration: max(0.01, r.end - r.start),
                                                                content: .trigger(.init(side: .right, design: TriggerDesign(spec: r.spec)))))
        }

        // Lightbar: keys, regrouping fades.
        let keys = all.compactMap { e -> (time: Double, color: LightbarColor, interp: LightbarInterpolation, id: String)? in
            if case let .lightbar(color, interp) = e.action { (e.time, color, interp, e.id) } else { nil }
        }.sorted { $0.time < $1.time }
        var composed: [(start: Double, key: ComposerEvent.LightbarKey, id: String)] = []
        var i = 0
        var linearWithoutMarker = false
        while i < keys.count {
            let k = keys[i]
            if k.id.hasSuffix(Self.fadeMarker), i + 1 < keys.count, keys[i + 1].interp == .linear,
               keys[i + 1].id + Self.fadeMarker == k.id {
                let target = keys[i + 1]
                composed.append((k.time, Self.key(target.color, fade: target.time - k.time), target.id))
                i += 2
                continue
            }
            if k.interp == .linear, i > 0 { linearWithoutMarker = true }
            composed.append((k.time, Self.key(k.color, fade: 0), k.id))
            i += 1
        }
        if linearWithoutMarker { notes.append("Linear lightbar fades from another tool load as colour steps.") }
        for (n, c) in composed.enumerated() {
            let next = n + 1 < composed.count ? composed[n + 1].start : max(end, c.start + max(0.5, c.key.fade))
            tracks[index(.lightbar)].events.append(ComposerEvent(id: uuid(c.id), start: c.start, duration: max(0.01, next - c.start), content: .lightbar(c.key)))
        }

        for t in tracks.indices { tracks[t].events.sort { $0.start < $1.start } }
        duration = min(Self.maximumDuration, max(4, contentEnd))
    }

    private static func lanes(for side: HapticSide) -> [ComposerTrack.Kind] {
        switch side {
        case .left: [.leftActuator]
        case .right: [.rightActuator]
        case .both: [.leftActuator, .rightActuator]
        }
    }

    private static func key(_ color: LightbarColor, fade: Double) -> ComposerEvent.LightbarKey {
        ComposerEvent.LightbarKey(red: Int(color.red), green: Int(color.green), blue: Int(color.blue), fade: max(0, fade))
    }

    /// The Composer parameters and event length for a library effect.
    private static func parametric(_ effect: HapticEffect) -> (ComposerEvent.Parametric, Double) {
        switch effect {
        case let .tone(a, f, d): (.init(kind: .tone, intensity: a, frequency: f), max(0.01, d))
        case let .texture(a, g, d): (.init(kind: .texture, intensity: a, grainRate: g), max(0.01, d))
        case let .click(a, f): (.init(kind: .click, intensity: a, frequency: f), 0.1)
        case let .detent(a, f): (.init(kind: .detent, intensity: a, frequency: f), 0.1)
        case let .impact(a): (.init(kind: .impact, intensity: a), 0.15)
        }
    }
}

// MARK: Files

extension ComposerDocument {
    /// Reads a Composer file: the library's `.tactilepattern` (what Tactile
    /// Lab writes since Tactile 0.4) or the app's earlier Composer JSON.
    static func load(_ data: Data, clipBase: URL?, notes: inout [String]) throws -> ComposerDocument {
        if let legacy = try? JSONDecoder().decode(ComposerDocument.self, from: data) {
            guard legacy.schemaVersion <= schemaVersion else { throw ComposerFileError.newerSchema(legacy.schemaVersion) }
            notes.append("Opened an earlier Tactile Lab Composer file; Save writes it in the library's pattern format.")
            return legacy
        }
        do {
            return ComposerDocument(pattern: try HapticPattern(data: data), clipBase: clipBase, notes: &notes)
        } catch HapticPattern.Failure.unsupportedSchemaVersion(let v) {
            throw ComposerFileError.newerSchema(v)
        }
    }

    /// The `.tactilepattern` JSON written by Save.
    func patternData() throws -> Data { try pattern.encoded() }
}

// MARK: Preview

/// The offline actuator render shown under the timeline, from the library's
/// `HapticPatternRenderer.renderOffline` (the same samples live playback streams).
struct ComposerMix: Sendable {
    static let sampleRate = HapticsFormat.sampleRate
    var left: [Float] = []
    var right: [Float] = []
    /// Samples at full scale (the renderer clips there).
    var clipped = 0
    var duration: Double { Double(left.count) / Self.sampleRate }
    var isSilent: Bool { !left.contains { $0 != 0 } && !right.contains { $0 != 0 } }

    init() {}

    init(_ preview: HapticPreview) {
        left = preview.left
        right = preview.right
        clipped = left.reduce(0) { $0 + (abs($1) >= 0.9999 ? 1 : 0) } + right.reduce(0) { $0 + (abs($1) >= 0.9999 ? 1 : 0) }
    }

    static func render(_ document: ComposerDocument) -> ComposerMix {
        (try? HapticPatternRenderer.renderOffline(document.pattern, clipLoader: ComposerClips.loader)).map(ComposerMix.init) ?? ComposerMix()
    }
}

/// Decoded audio clips shared by previews; a missing clip renders as silence
/// in the preview (playback reports it as an error).
enum ComposerClips {
    private static let cache = Mutex<[String: DecodedAudioClip]>([:])

    static let loader: HapticClipLoader = { clip in
        if let hit = cache.withLock({ $0[clip.path] }) { return hit }
        do {
            let decoded = try HapticPatternRenderer.fileClipLoader(relativeTo: nil)(clip)
            cache.withLock { $0[clip.path] = decoded }
            return decoded
        } catch {
            return DecodedAudioClip(sampleRate: HapticsFormat.sampleRate, channels: [[0]])
        }
    }

    /// Seconds of audio in the file, or nil when it cannot be read.
    static func length(_ path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
