import Foundation
import Tactile
import UniformTypeIdentifiers

/// The Composer's editing model: four lanes (left and right actuator,
/// triggers, lightbar) of events with a start and a length.
///
/// Files are the library's `HapticPattern` (`.tactilepattern`, schema 1):
/// `ComposerPattern.swift` converts both ways, and the preview and playback
/// use the converted pattern. This type's own Codable form is the app's
/// pre-0.4 Composer file format, still read by `load` so older files open;
/// unknown event kinds in those files decode as `.unsupported` (they cannot
/// be written to the library format).
struct ComposerDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let fileExtension = HapticPattern.fileExtension
    /// Longest composition the lab plays (the operation limit is 60 s).
    static let maximumDuration = 60.0

    var schemaVersion = ComposerDocument.schemaVersion
    var name = "Untitled pattern"
    var duration = 4.0
    var tracks: [ComposerTrack] = ComposerTrack.Kind.allCases.map { ComposerTrack(kind: $0) }

    /// The end of the last event, which is how long playback runs.
    var contentEnd: Double { tracks.flatMap(\.events).map(\.end).max() ?? 0 }

    func track(_ kind: ComposerTrack.Kind) -> ComposerTrack? { tracks.first { $0.kind == kind } }

    func event(_ id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in tracks.enumerated() {
            if let i = track.events.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    static var example: ComposerDocument {
        var doc = ComposerDocument(name: "Example: reload and fire")
        doc.tracks[0].events = [
            ComposerEvent(start: 0.2, duration: 0.3, content: .parametric(.init(kind: .texture, intensity: 0.4, grainRate: 40))),
            ComposerEvent(start: 1.2, duration: 0.2, content: .parametric(.init(kind: .impact, intensity: 0.9))),
        ]
        doc.tracks[1].events = [
            ComposerEvent(start: 0.6, duration: 0.4, content: .parametric(.init(kind: .click, intensity: 0.8, frequency: 250, repeatInterval: 0.1))),
            ComposerEvent(start: 1.2, duration: 0.35, content: .rumble(.init(level: 180))),
        ]
        doc.tracks[2].events = [
            ComposerEvent(start: 0, duration: 1.2, content: .trigger(.init(side: .right, design: TriggerDesign.presets[0].design))),
            ComposerEvent(start: 1.2, duration: 0.8, content: .trigger(.init(side: .right, design: .off))),
        ]
        doc.tracks[3].events = [
            ComposerEvent(start: 0, duration: 1.2, content: .lightbar(.init(red: 0, green: 120, blue: 255))),
            ComposerEvent(start: 1.2, duration: 0.4, content: .lightbar(.init(red: 255, green: 60, blue: 0, fade: 0.05))),
        ]
        return doc
    }
}

struct ComposerTrack: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case leftActuator, rightActuator, triggers, lightbar
        var title: String {
            switch self {
            case .leftActuator: "Left actuator"
            case .rightActuator: "Right actuator"
            case .triggers: "Triggers"
            case .lightbar: "Lightbar"
            }
        }
        var symbol: String {
            switch self {
            case .leftActuator: "l.circle"
            case .rightActuator: "r.circle"
            case .triggers: "l2.button.angledtop.vertical.left"
            case .lightbar: "light.strip.2"
            }
        }
        var isActuator: Bool { self == .leftActuator || self == .rightActuator }
        var side: HapticSide? { self == .leftActuator ? .left : self == .rightActuator ? .right : nil }
    }

    var id = UUID()
    var kind: Kind
    var muted = false
    var events: [ComposerEvent] = []
}

struct ComposerEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var duration: Double
    var content: Content

    var end: Double { start + duration }

    enum Content: Equatable, Sendable {
        case parametric(Parametric)
        case audioClip(AudioClip)
        case rumble(RumbleLevel)
        case trigger(TriggerChange)
        case lightbar(LightbarKey)
        /// A kind this version does not know; kept verbatim.
        case unsupported(type: String, json: Data)

        var title: String {
            switch self {
            case .parametric(let p): p.kind.title
            case .audioClip(let a): a.displayName
            case .rumble(let r): "Rumble \(r.level)"
            case .trigger(let t): "\(t.side.title): \(t.design.summary)"
            case .lightbar(let l): String(format: "#%02X%02X%02X", l.red, l.green, l.blue)
            case .unsupported(let type, _): "Unsupported: \(type)"
            }
        }
    }

    /// A parametric effect with the library's parameters. Click, detent and
    /// impact are one-shots: they play once at the start, or every
    /// `repeatInterval` seconds while the event lasts. Tone and texture fill
    /// the event's duration.
    struct Parametric: Codable, Equatable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case tone, click, detent, texture, impact
            var title: String { rawValue.capitalized }
            var isOneShot: Bool { self == .click || self == .detent || self == .impact }
            var usesFrequency: Bool { self == .tone || self == .click || self == .detent }
            var defaultFrequency: Float { self == .click ? 250 : self == .detent ? 170 : 160 }
        }
        var kind: Kind
        var intensity: Float = 0.6
        var frequency: Float = 160
        var grainRate: Float = 60
        var repeatInterval: Double = 0

        /// The library effect for one voice of this event.
        func effect(duration: Double) -> HapticEffect {
            switch kind {
            case .tone: .tone(intensity: intensity, frequency: frequency, duration: duration)
            case .click: .click(intensity: intensity, frequency: frequency)
            case .detent: .detent(intensity: intensity, frequency: frequency)
            case .texture: .texture(intensity: intensity, grainRate: grainRate, duration: duration)
            case .impact: .impact(intensity: intensity)
            }
        }
    }

    /// An audio file played into the actuator, from `trim` seconds into the
    /// file, for the event's duration.
    struct AudioClip: Codable, Equatable, Sendable {
        var path: String
        var gain: Float = 1
        var trim: Double = 0
        /// Library clip side when it is not the lane's own (a stereo clip on
        /// `.both`); nil plays a mono mix on the lane's actuator.
        var side: HapticSide?
        var url: URL { URL(fileURLWithPath: path) }
        var displayName: String { url.lastPathComponent }
    }

    /// Legacy rumble on this track's motor, 0–255. The Composer renders it as a
    /// low-frequency vibration into the actuator mix.
    struct RumbleLevel: Codable, Equatable, Sendable {
        var level: Int = 160
    }

    struct TriggerChange: Codable, Equatable, Sendable {
        enum Side: String, Codable, CaseIterable, Sendable {
            case left, right, both
            var title: String { rawValue.capitalized }
        }
        var side: Side = .right
        var design = TriggerDesign()
    }

    struct LightbarKey: Codable, Equatable, Sendable {
        var red: Int = 0
        var green: Int = 120
        var blue: Int = 255
        /// Seconds to fade in from the previous key (display only for now).
        var fade: Double = 0
        var color: LightbarColor { LightbarColor(red: UInt8(clamping: red), green: UInt8(clamping: green), blue: UInt8(clamping: blue)) }
    }
}

// MARK: Codable content

extension ComposerEvent.Content: Codable {
    private enum Keys: String, CodingKey { case type, parametric, audioClip, rumble, trigger, lightbar }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "parametric": self = .parametric(try c.decode(ComposerEvent.Parametric.self, forKey: .parametric))
        case "audioClip": self = .audioClip(try c.decode(ComposerEvent.AudioClip.self, forKey: .audioClip))
        case "rumble": self = .rumble(try c.decode(ComposerEvent.RumbleLevel.self, forKey: .rumble))
        case "trigger": self = .trigger(try c.decode(ComposerEvent.TriggerChange.self, forKey: .trigger))
        case "lightbar": self = .lightbar(try c.decode(ComposerEvent.LightbarKey.self, forKey: .lightbar))
        default:
            let raw = try AnyJSON(from: decoder)
            self = .unsupported(type: type, json: try JSONEncoder().encode(raw))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .parametric(let v): try c.encode("parametric", forKey: .type); try c.encode(v, forKey: .parametric)
        case .audioClip(let v): try c.encode("audioClip", forKey: .type); try c.encode(v, forKey: .audioClip)
        case .rumble(let v): try c.encode("rumble", forKey: .type); try c.encode(v, forKey: .rumble)
        case .trigger(let v): try c.encode("trigger", forKey: .type); try c.encode(v, forKey: .trigger)
        case .lightbar(let v): try c.encode("lightbar", forKey: .type); try c.encode(v, forKey: .lightbar)
        case .unsupported(_, let json):
            try JSONDecoder().decode(AnyJSON.self, from: json).encode(to: encoder)
        }
    }
}

/// Minimal JSON value, used to carry unknown event kinds through a save.
enum AnyJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([AnyJSON]), object([String: AnyJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: Files

extension UTType {
    /// Declared by extension only; the app does not register a document type.
    static var tactilePattern: UTType {
        UTType(filenameExtension: ComposerDocument.fileExtension, conformingTo: .json) ?? .json
    }
}

enum ComposerFileError: LocalizedError {
    case newerSchema(Int)
    var errorDescription: String? {
        switch self {
        case .newerSchema(let v): "This pattern uses schema \(v); this version of Tactile Lab reads up to \(ComposerDocument.schemaVersion)."
        }
    }
}

extension ComposerDocument {
    /// The pre-0.4 app format (tests and migration only; Save writes `patternData()`).
    func legacyEncoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
