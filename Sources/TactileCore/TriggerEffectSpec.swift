// A parameter-level description of a trigger effect: the factory call that
// builds it. `TriggerEffect` holds only the 11 wire bytes, which loses the
// arguments (several factories encode to the same mode); tools that edit an
// effect, draw it or export code need the arguments, so they work on a spec.

/// Which adaptive trigger.
public enum TriggerSide: String, Sendable, Codable, CaseIterable {
    case left, right
}

/// The factory call (and its arguments) behind a `TriggerEffect`.
/// Codable as `{"type": "weapon", "start": 2, "end": 6, "strength": 8}`.
public enum TriggerEffectSpec: Sendable, Hashable, Codable {
    case off
    case feedback(position: Int, strength: Int)
    case multiplePositionFeedback(strengths: [Int])
    case slopeFeedback(startPosition: Int, endPosition: Int, startStrength: Int, endStrength: Int)
    case weapon(start: Int, end: Int, strength: Int)
    case vibration(position: Int, amplitude: Int, frequency: Int)
    case multiplePositionVibration(frequency: Int, amplitudes: [Int])
    /// UNOFFICIAL.
    case bow(start: Int, end: Int, strength: Int, snapForce: Int)
    /// UNOFFICIAL.
    case galloping(start: Int, end: Int, firstFoot: Int, secondFoot: Int, frequency: Int)
    /// UNOFFICIAL.
    case machine(start: Int, end: Int, amplitudeA: Int, amplitudeB: Int, frequency: Int, period: Int)
    /// Bytes that no factory describes (experimentation); padded/truncated to 11.
    case raw(bytes: [UInt8])

    /// Builds the wire effect, validating the arguments exactly as the factories do.
    public func effect() throws(TriggerEffect.ValidationError) -> TriggerEffect {
        switch self {
        case .off: return .off
        case let .feedback(p, s): return try .feedback(position: p, strength: s)
        case let .multiplePositionFeedback(s): return try .multiplePositionFeedback(strengths: s)
        case let .slopeFeedback(sp, ep, ss, es):
            return try .slopeFeedback(startPosition: sp, endPosition: ep, startStrength: ss, endStrength: es)
        case let .weapon(s, e, st): return try .weapon(start: s, end: e, strength: st)
        case let .vibration(p, a, f): return try .vibration(position: p, amplitude: a, frequency: f)
        case let .multiplePositionVibration(f, a): return try .multiplePositionVibration(frequency: f, amplitudes: a)
        case let .bow(s, e, st, sn): return try .bow(start: s, end: e, strength: st, snapForce: sn)
        case let .galloping(s, e, f1, f2, f):
            return try .galloping(start: s, end: e, firstFoot: f1, secondFoot: f2, frequency: f)
        case let .machine(s, e, a, b, f, p):
            return try .machine(start: s, end: e, amplitudeA: a, amplitudeB: b, frequency: f, period: p)
        case let .raw(b): return TriggerEffect(rawBytes: b)
        }
    }

    /// The factory name, as used in the JSON `type` field.
    public var typeName: String {
        switch self {
        case .off: "off"
        case .feedback: "feedback"
        case .multiplePositionFeedback: "multiplePositionFeedback"
        case .slopeFeedback: "slopeFeedback"
        case .weapon: "weapon"
        case .vibration: "vibration"
        case .multiplePositionVibration: "multiplePositionVibration"
        case .bow: "bow"
        case .galloping: "galloping"
        case .machine: "machine"
        case .raw: "raw"
        }
    }

    /// True for effects Sony documents (off, feedback, weapon, vibration families).
    public var isOfficial: Bool {
        switch self {
        case .bow, .galloping, .machine, .raw: false
        default: true
        }
    }

    /// Recovers a spec from wire bytes. Feedback and vibration come back as
    /// their multiple-position forms (the single-position and slope factories
    /// encode to the same bytes); unknown modes come back as `.raw`.
    /// `try spec.effect()` reproduces `effect` byte for byte.
    public init(decoding effect: TriggerEffect) {
        let b = effect.bytes
        func zones() -> UInt16 { UInt16(b[1]) | UInt16(b[2]) << 8 }
        func u32() -> UInt32 { UInt32(b[3]) | UInt32(b[4]) << 8 | UInt32(b[5]) << 16 | UInt32(b[6]) << 24 }
        /// Lowest and highest set bits of a two-bit zone field, when exactly two are set.
        func pair(_ z: UInt16) -> (Int, Int)? {
            guard z.nonzeroBitCount == 2 else { return nil }
            return (z.trailingZeroBitCount, 15 - z.leadingZeroBitCount)
        }
        let candidate: TriggerEffectSpec?
        switch effect.mode {
        case .off?:
            candidate = .off
        case .feedback?:
            let z = zones(), f = u32()
            let s = (0..<10).map { i in z & (1 << i) != 0 ? Int((f >> (3 * UInt32(i))) & 7) + 1 : 0 }
            candidate = .multiplePositionFeedback(strengths: s)
        case .vibration?:
            let z = zones(), a = u32()
            let amps = (0..<10).map { i in z & (1 << i) != 0 ? Int((a >> (3 * UInt32(i))) & 7) + 1 : 0 }
            candidate = .multiplePositionVibration(frequency: Int(b[9]), amplitudes: amps)
        case .weapon?:
            candidate = pair(zones()).map { .weapon(start: $0.0, end: $0.1, strength: Int(b[3] & 7) + 1) }
        case .bow?:
            candidate = pair(zones()).map {
                .bow(start: $0.0, end: $0.1, strength: Int(b[3] & 7) + 1, snapForce: Int((b[3] >> 3) & 7) + 1)
            }
        case .galloping?:
            candidate = pair(zones()).map {
                .galloping(start: $0.0, end: $0.1, firstFoot: Int((b[3] >> 3) & 7), secondFoot: Int(b[3] & 7),
                           frequency: Int(b[4]))
            }
        case .machine?:
            candidate = pair(zones()).map {
                .machine(start: $0.0, end: $0.1, amplitudeA: Int(b[3] & 7), amplitudeB: Int((b[3] >> 3) & 7),
                         frequency: Int(b[4]), period: Int(b[5]))
            }
        case nil:
            candidate = nil
        }
        // Accept the decoded form only when it re-encodes to the same bytes
        // (stray bits in unused bytes, out-of-range zones and so on stay raw).
        if let candidate, (try? candidate.effect())?.bytes == b {
            self = candidate
        } else {
            self = .raw(bytes: b)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, position, strength, strengths, startPosition, endPosition, startStrength, endStrength
        case start, end, amplitude, frequency, amplitudes, snapForce, firstFoot, secondFoot
        case amplitudeA, amplitudeB, period, bytes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys) throws -> Int { try c.decode(Int.self, forKey: k) }
        switch try c.decode(String.self, forKey: .type) {
        case "off": self = .off
        case "feedback": self = .feedback(position: try i(.position), strength: try i(.strength))
        case "multiplePositionFeedback":
            self = .multiplePositionFeedback(strengths: try c.decode([Int].self, forKey: .strengths))
        case "slopeFeedback":
            self = .slopeFeedback(startPosition: try i(.startPosition), endPosition: try i(.endPosition),
                                  startStrength: try i(.startStrength), endStrength: try i(.endStrength))
        case "weapon": self = .weapon(start: try i(.start), end: try i(.end), strength: try i(.strength))
        case "vibration":
            self = .vibration(position: try i(.position), amplitude: try i(.amplitude), frequency: try i(.frequency))
        case "multiplePositionVibration":
            self = .multiplePositionVibration(frequency: try i(.frequency),
                                              amplitudes: try c.decode([Int].self, forKey: .amplitudes))
        case "bow":
            self = .bow(start: try i(.start), end: try i(.end), strength: try i(.strength), snapForce: try i(.snapForce))
        case "galloping":
            self = .galloping(start: try i(.start), end: try i(.end), firstFoot: try i(.firstFoot),
                              secondFoot: try i(.secondFoot), frequency: try i(.frequency))
        case "machine":
            self = .machine(start: try i(.start), end: try i(.end), amplitudeA: try i(.amplitudeA),
                            amplitudeB: try i(.amplitudeB), frequency: try i(.frequency), period: try i(.period))
        case "raw": self = .raw(bytes: try c.decode([UInt8].self, forKey: .bytes))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown trigger effect type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .off: break
        case let .feedback(p, s):
            try c.encode(p, forKey: .position); try c.encode(s, forKey: .strength)
        case let .multiplePositionFeedback(s):
            try c.encode(s, forKey: .strengths)
        case let .slopeFeedback(sp, ep, ss, es):
            try c.encode(sp, forKey: .startPosition); try c.encode(ep, forKey: .endPosition)
            try c.encode(ss, forKey: .startStrength); try c.encode(es, forKey: .endStrength)
        case let .weapon(s, e, st):
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end); try c.encode(st, forKey: .strength)
        case let .vibration(p, a, f):
            try c.encode(p, forKey: .position); try c.encode(a, forKey: .amplitude); try c.encode(f, forKey: .frequency)
        case let .multiplePositionVibration(f, a):
            try c.encode(f, forKey: .frequency); try c.encode(a, forKey: .amplitudes)
        case let .bow(s, e, st, sn):
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
            try c.encode(st, forKey: .strength); try c.encode(sn, forKey: .snapForce)
        case let .galloping(s, e, f1, f2, f):
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
            try c.encode(f1, forKey: .firstFoot); try c.encode(f2, forKey: .secondFoot); try c.encode(f, forKey: .frequency)
        case let .machine(s, e, a, b, f, p):
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
            try c.encode(a, forKey: .amplitudeA); try c.encode(b, forKey: .amplitudeB)
            try c.encode(f, forKey: .frequency); try c.encode(p, forKey: .period)
        case let .raw(b):
            try c.encode(TriggerEffect(rawBytes: b).bytes, forKey: .bytes)
        }
    }
}
