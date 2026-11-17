// Haptic patterns: timed tracks of parametric effects, audio clips, rumble,
// trigger-effect changes and lightbar colour keys, stored as JSON in
// `.tactilepattern` files with a schema version.

public import Foundation
public import TactileCore

/// A haptic pattern. Value type; Codable as the `.tactilepattern` JSON format.
public struct HapticPattern: Sendable, Hashable, Codable {
    /// File extension (without the dot).
    public static let fileExtension = "tactilepattern"
    /// Uniform type identifier apps may declare for the format.
    public static let typeIdentifier = "com.tactile.pattern"
    /// Schema version written by this library. Readers accept this version and older.
    public static let currentSchemaVersion = 1
    /// Longest pattern that is rendered, in seconds (ten minutes).
    public static let maximumDuration: Double = 600

    public var schemaVersion: Int
    public var name: String
    public var tracks: [HapticPatternTrack]

    public init(name: String = "Untitled", tracks: [HapticPatternTrack] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.tracks = tracks
    }

    /// End of the last event, in seconds, from what the pattern itself knows:
    /// effect lengths, rumble durations, and audio clips whose trim end is set
    /// (an untrimmed clip counts from its start time only; the rendered
    /// preview knows its real length). Capped at `maximumDuration`.
    public var duration: Double {
        var end = 0.0
        for track in tracks where !track.isMuted {
            for e in track.events {
                end = max(end, e.time + e.action.knownDuration)
            }
        }
        return min(end, Self.maximumDuration)
    }

    // MARK: Files

    public enum Failure: Error, Sendable, Equatable {
        /// The file was written by a newer library.
        case unsupportedSchemaVersion(Int)
        case unreadableClip(path: String, reason: String)
    }

    /// Pretty-printed JSON with sorted keys (stable diffs).
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Decodes JSON, rejecting a schema newer than `currentSchemaVersion`.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(HapticPattern.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, name, tracks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .schemaVersion)
        guard v <= Self.currentSchemaVersion else { throw Failure.unsupportedSchemaVersion(v) }
        schemaVersion = v
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        tracks = try c.decodeIfPresent([HapticPatternTrack].self, forKey: .tracks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(name, forKey: .name)
        try c.encode(tracks, forKey: .tracks)
    }
}

/// A named lane of events. Muted tracks are neither rendered nor played.
public struct HapticPatternTrack: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var isMuted: Bool
    public var events: [HapticPatternEvent]

    public init(id: String = UUID().uuidString, name: String, isMuted: Bool = false, events: [HapticPatternEvent] = []) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.events = events
    }

    private enum CodingKeys: String, CodingKey { case id, name, isMuted, events }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        events = try c.decodeIfPresent([HapticPatternEvent].self, forKey: .events) ?? []
    }
}

/// One timed event. `time` is seconds from the start of the pattern.
public struct HapticPatternEvent: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var time: Double
    public var action: HapticPatternAction

    public init(id: String = UUID().uuidString, time: Double, _ action: HapticPatternAction) {
        self.id = id
        self.time = time
        self.action = action
    }

    private enum CodingKeys: String, CodingKey { case id, time, type, effect, side, clip, left, right, duration, color, interpolation }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        time = try c.decode(Double.self, forKey: .time)
        switch try c.decode(String.self, forKey: .type) {
        case "effect":
            action = .effect(try c.decode(HapticEffect.self, forKey: .effect),
                             side: try c.decodeIfPresent(HapticSide.self, forKey: .side) ?? .both)
        case "audio":
            action = .audio(try c.decode(HapticAudioClip.self, forKey: .clip))
        case "rumble":
            action = .rumble(Rumble(left: try c.decode(UInt8.self, forKey: .left), right: try c.decode(UInt8.self, forKey: .right)),
                             duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0)
        case "trigger":
            action = .trigger(try c.decode(TriggerSide.self, forKey: .side), try c.decode(TriggerEffectSpec.self, forKey: .effect))
        case "lightbar":
            action = .lightbar(try c.decode(LightbarColor.self, forKey: .color),
                               interpolation: try c.decodeIfPresent(LightbarInterpolation.self, forKey: .interpolation) ?? .step)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        switch action {
        case let .effect(e, side):
            try c.encode("effect", forKey: .type)
            try c.encode(e, forKey: .effect)
            try c.encode(side, forKey: .side)
        case let .audio(clip):
            try c.encode("audio", forKey: .type)
            try c.encode(clip, forKey: .clip)
        case let .rumble(r, d):
            try c.encode("rumble", forKey: .type)
            try c.encode(r.left, forKey: .left)
            try c.encode(r.right, forKey: .right)
            try c.encode(d, forKey: .duration)
        case let .trigger(side, spec):
            try c.encode("trigger", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(spec, forKey: .effect)
        case let .lightbar(color, interp):
            try c.encode("lightbar", forKey: .type)
            try c.encode(color, forKey: .color)
            try c.encode(interp, forKey: .interpolation)
        }
    }
}

/// How the lightbar reaches a colour key.
public enum LightbarInterpolation: String, Sendable, Hashable, Codable, CaseIterable {
    /// Jump to the colour at the key's time.
    case step
    /// Fade linearly from the previous key's colour, arriving at the key's time.
    case linear
}

public enum HapticPatternAction: Sendable, Hashable {
    /// A parametric effect (TactileHaptics `HapticEffect`).
    case effect(HapticEffect, side: HapticSide)
    /// A referenced audio file played through the haptics stream.
    case audio(HapticAudioClip)
    /// Rumble emulated on the voice coils (as the mixer does). `duration` 0
    /// holds until the next rumble event or the end of the pattern.
    case rumble(Rumble, duration: Double)
    /// Switch a trigger to an effect (held until the next change).
    case trigger(TriggerSide, TriggerEffectSpec)
    /// A lightbar colour key.
    case lightbar(LightbarColor, interpolation: LightbarInterpolation)

    /// Length known without decoding audio (see `HapticPattern.duration`).
    var knownDuration: Double {
        switch self {
        case let .effect(e, _):
            let d = e.duration
            return d.isFinite ? max(0, d) : HapticPattern.maximumDuration
        case let .audio(clip):
            if let end = clip.trimEnd { return max(0, end - clip.trimStart) }
            return 0
        case let .rumble(_, d): return d.isFinite ? max(0, d) : 0
        case .trigger, .lightbar: return 0
        }
    }
}

/// An audio file referenced by a pattern.
public struct HapticAudioClip: Sendable, Hashable, Codable {
    /// File path; relative paths resolve against the pattern file's folder.
    public var path: String
    /// Linear gain (0…4).
    public var gain: Float
    /// Seconds skipped at the start of the file.
    public var trimStart: Double
    /// Seconds into the file where playback stops (nil = end of file).
    public var trimEnd: Double?
    /// Which actuator(s): `.both` keeps a stereo file's left/right; `.left`
    /// or `.right` sends a mono mix to one side.
    public var side: HapticSide

    public init(path: String, gain: Float = 1, trimStart: Double = 0, trimEnd: Double? = nil, side: HapticSide = .both) {
        self.path = path
        self.gain = gain
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.side = side
    }

    private enum CodingKeys: String, CodingKey { case path, gain, trimStart, trimEnd, side }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        side = try c.decodeIfPresent(HapticSide.self, forKey: .side) ?? .both
    }
}

// MARK: Control timeline

/// A trigger or lightbar change at a point in time (from `controlTimeline`).
public struct HapticPatternControl: Sendable, Hashable {
    public enum Change: Sendable, Hashable {
        case trigger(TriggerSide, TriggerEffect)
        case lightbar(LightbarColor)
    }
    public var time: Double
    public var change: Change
}

extension HapticPattern {
    /// Every trigger and lightbar change in time order. Linear lightbar keys
    /// are expanded into steps at `lightbarRate` Hz (the output report is rate
    /// limited, so 30 Hz is plenty). Invalid trigger specs are skipped.
    public func controlTimeline(lightbarRate: Double = 30) -> [HapticPatternControl] {
        var out: [(order: Int, HapticPatternControl)] = []
        var lightKeys: [(time: Double, color: LightbarColor, interp: LightbarInterpolation, order: Int)] = []
        var order = 0
        for track in tracks where !track.isMuted {
            for e in track.events {
                order += 1
                guard e.time.isFinite, e.time >= 0, e.time <= Self.maximumDuration else { continue }
                switch e.action {
                case let .trigger(side, spec):
                    if let effect = try? spec.effect() {
                        out.append((order, HapticPatternControl(time: e.time, change: .trigger(side, effect))))
                    }
                case let .lightbar(color, interp):
                    lightKeys.append((e.time, color, interp, order))
                default:
                    break
                }
            }
        }
        lightKeys.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        let step = 1 / max(1, min(lightbarRate.isFinite ? lightbarRate : 30, 240))
        var previous: (time: Double, color: LightbarColor)?
        for key in lightKeys {
            if key.interp == .linear, let prev = previous, key.time > prev.time {
                var t = prev.time + step
                while t < key.time - step / 2 {
                    let f = (t - prev.time) / (key.time - prev.time)
                    out.append((key.order, HapticPatternControl(time: t, change: .lightbar(prev.color.mixed(with: key.color, fraction: f)))))
                    t += step
                }
            }
            out.append((key.order, HapticPatternControl(time: key.time, change: .lightbar(key.color))))
            previous = (key.time, key.color)
        }
        return out.sorted { ($0.1.time, $0.order) < ($1.1.time, $1.order) }.map(\.1)
    }

    /// The lightbar colour at `time` (nil before the first key).
    public func lightbarColor(at time: Double) -> LightbarColor? {
        var color: LightbarColor?
        for c in controlTimeline() where c.time <= time {
            if case let .lightbar(l) = c.change { color = l }
        }
        return color
    }
}

extension LightbarColor {
    /// Linear blend towards `other` (fraction 0 = self, 1 = other).
    func mixed(with other: LightbarColor, fraction: Double) -> LightbarColor {
        let f = min(max(fraction.isNaN ? 0 : fraction, 0), 1)
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded()) }
        return LightbarColor(red: m(red, other.red), green: m(green, other.green), blue: m(blue, other.blue))
    }
}
