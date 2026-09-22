// Adaptive-trigger effect encoders.
//
// Adapted from Nielk1's "TriggerEffectGenerator" gist (MIT licence), with
// attribution in THIRD_PARTY_NOTICES.md. Parameter ranges, zone bitfields and
// byte layouts follow that gist; the Swift code is a fresh translation.
//
// Each effect encodes to 11 bytes placed in the output report's per-trigger slot.

/// An adaptive-trigger effect. Construct via the static factories, which validate
/// parameters exactly as the reference implementation does.
public struct TriggerEffect: Sendable, Hashable, Codable {
    /// Wire mode bytes.
    public enum Mode: UInt8, Sendable, Codable, CaseIterable {
        // Official (used by Sony's SDK and exposed in some form by Apple).
        case off = 0x05
        case feedback = 0x21
        case weapon = 0x25
        case vibration = 0x26
        // Unofficial (present in firmware, not documented by Sony).
        case bow = 0x22
        case galloping = 0x23
        case machine = 0x27

        public var isOfficial: Bool {
            switch self {
            case .off, .feedback, .weapon, .vibration: true
            case .bow, .galloping, .machine: false
            }
        }
    }

    public static let byteCount = 11

    /// The 11 wire bytes.
    public let bytes: [UInt8]

    public var mode: Mode? { bytes.first.flatMap(Mode.init(rawValue:)) }

    /// Creates an effect from raw bytes (for experimentation). Pads or truncates to 11.
    public init(rawBytes: [UInt8]) {
        var b = Array(rawBytes.prefix(Self.byteCount))
        b.append(contentsOf: repeatElement(0, count: Self.byteCount - b.count))
        bytes = b
    }

    private enum CodingKeys: String, CodingKey { case bytes }

    /// Decodes through `init(rawBytes:)` so a decoded effect always has exactly
    /// 11 bytes (the output report encoder relies on that invariant).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rawBytes: try c.decode([UInt8].self, forKey: .bytes))
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case outOfRange(parameter: String, value: Int, allowed: ClosedRange<Int>)
        case ordering(String)
    }

    private static func check(_ name: String, _ v: Int, _ r: ClosedRange<Int>) throws(ValidationError) {
        guard r.contains(v) else { throw .outOfRange(parameter: name, value: v, allowed: r) }
    }

    private static func zonesBytes(_ zones: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: zones), UInt8(truncatingIfNeeded: zones >> 8)]
    }

    private static func u32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    // MARK: Official

    /// No resistance.
    public static let off = TriggerEffect(rawBytes: [Mode.off.rawValue])

    /// Constant resistance from `position` (0–9) to the end of travel. `strength` 0–8; 0 = off.
    public static func feedback(position: Int, strength: Int) throws(ValidationError) -> TriggerEffect {
        try check("position", position, 0...9)
        try check("strength", strength, 0...8)
        guard strength > 0 else { return .off }
        var strengths = [Int](repeating: 0, count: 10)
        for i in position..<10 { strengths[i] = strength }
        return try multiplePositionFeedback(strengths: strengths)
    }

    /// Per-zone resistance; `strengths` has 10 entries, each 0–8.
    public static func multiplePositionFeedback(strengths: [Int]) throws(ValidationError) -> TriggerEffect {
        guard strengths.count == 10 else {
            throw .outOfRange(parameter: "strengths.count", value: strengths.count, allowed: 10...10)
        }
        var forceZones: UInt32 = 0
        var activeZones: UInt16 = 0
        for (i, s) in strengths.enumerated() {
            try check("strengths[\(i)]", s, 0...8)
            if s > 0 {
                forceZones |= UInt32((s - 1) & 7) << (3 * i)
                activeZones |= 1 << i
            }
        }
        guard activeZones != 0 else { return .off }
        return TriggerEffect(rawBytes: [Mode.feedback.rawValue] + zonesBytes(activeZones) + u32Bytes(forceZones))
    }

    /// Resistance ramping linearly from `startStrength` at `startPosition` to
    /// `endStrength` at `endPosition`, held to the end of travel.
    /// Rounds half-to-even, matching the reference (C# Math.Round).
    public static func slopeFeedback(startPosition: Int, endPosition: Int, startStrength: Int, endStrength: Int)
        throws(ValidationError) -> TriggerEffect
    {
        try check("startPosition", startPosition, 0...8)
        try check("endPosition", endPosition, 0...9)
        guard endPosition > startPosition else { throw .ordering("endPosition must be > startPosition") }
        try check("startStrength", startStrength, 1...8)
        try check("endStrength", endStrength, 1...8)
        var strengths = [Int](repeating: 0, count: 10)
        let slope = Float(endStrength - startStrength) / Float(endPosition - startPosition)
        for i in startPosition..<10 {
            if i <= endPosition {
                strengths[i] = Int((Float(startStrength) + slope * Float(i - startPosition)).rounded(.toNearestOrEven))
            } else {
                strengths[i] = endStrength
            }
        }
        return try multiplePositionFeedback(strengths: strengths)
    }

    /// A "trigger break": resistance between `start` (2–7) and `end` (start+1…8), releasing past it.
    public static func weapon(start: Int, end: Int, strength: Int) throws(ValidationError) -> TriggerEffect {
        try check("start", start, 2...7)
        try check("end", end, 0...8)
        guard end > start else { throw .ordering("end must be > start") }
        try check("strength", strength, 0...8)
        guard strength > 0 else { return .off }
        let zones: UInt16 = (1 << start) | (1 << end)
        return TriggerEffect(rawBytes: [Mode.weapon.rawValue] + zonesBytes(zones) + [UInt8(strength - 1)])
    }

    /// Vibration from `position` (0–9) to the end of travel. `amplitude` 0–8, `frequency` Hz 0–255.
    public static func vibration(position: Int, amplitude: Int, frequency: Int) throws(ValidationError) -> TriggerEffect {
        try check("position", position, 0...9)
        try check("amplitude", amplitude, 0...8)
        try check("frequency", frequency, 0...255)
        guard amplitude > 0, frequency > 0 else { return .off }
        var amps = [Int](repeating: 0, count: 10)
        for i in position..<10 { amps[i] = amplitude }
        return try multiplePositionVibration(frequency: frequency, amplitudes: amps)
    }

    /// Per-zone vibration amplitudes (10 entries, 0–8) at one `frequency`.
    public static func multiplePositionVibration(frequency: Int, amplitudes: [Int]) throws(ValidationError) -> TriggerEffect {
        try check("frequency", frequency, 0...255)
        guard amplitudes.count == 10 else {
            throw .outOfRange(parameter: "amplitudes.count", value: amplitudes.count, allowed: 10...10)
        }
        guard frequency > 0 else { return .off }
        var ampZones: UInt32 = 0
        var activeZones: UInt16 = 0
        for (i, a) in amplitudes.enumerated() {
            try check("amplitudes[\(i)]", a, 0...8)
            if a > 0 {
                ampZones |= UInt32((a - 1) & 7) << (3 * i)
                activeZones |= 1 << i
            }
        }
        guard activeZones != 0 else { return .off }
        var b = [Mode.vibration.rawValue] + zonesBytes(activeZones) + u32Bytes(ampZones)
        b += [0, 0, UInt8(frequency)]
        return TriggerEffect(rawBytes: b)
    }

    // MARK: Unofficial

    /// Bow string: resistance from `start` to `end`, then a snap-back force. UNOFFICIAL.
    public static func bow(start: Int, end: Int, strength: Int, snapForce: Int) throws(ValidationError) -> TriggerEffect {
        try check("start", start, 0...8)
        try check("end", end, 0...8)
        guard start < end else { throw .ordering("start must be < end") }
        try check("strength", strength, 0...8)
        try check("snapForce", snapForce, 0...8)
        guard end > 0, strength > 0, snapForce > 0 else { return .off }
        let zones: UInt16 = (1 << start) | (1 << end)
        let pair = UInt16((strength - 1) & 7) | UInt16((snapForce - 1) & 7) << 3
        return TriggerEffect(rawBytes: [Mode.bow.rawValue] + zonesBytes(zones) + zonesBytes(pair))
    }

    /// Galloping horse: two "feet" per cycle between `start` and `end`. UNOFFICIAL.
    /// `firstFoot` 0–6, `secondFoot` firstFoot+1…7 (timing ratio), `frequency` Hz.
    public static func galloping(start: Int, end: Int, firstFoot: Int, secondFoot: Int, frequency: Int)
        throws(ValidationError) -> TriggerEffect
    {
        try check("start", start, 0...8)
        try check("end", end, 0...9)
        guard start < end else { throw .ordering("start must be < end") }
        try check("secondFoot", secondFoot, 0...7)
        try check("firstFoot", firstFoot, 0...6)
        guard firstFoot < secondFoot else { throw .ordering("firstFoot must be < secondFoot") }
        try check("frequency", frequency, 0...255)
        guard frequency > 0 else { return .off }
        let zones: UInt16 = (1 << start) | (1 << end)
        let timeAndRatio = UInt8(secondFoot & 7) | UInt8(firstFoot & 7) << 3
        return TriggerEffect(rawBytes: [Mode.galloping.rawValue] + zonesBytes(zones) + [timeAndRatio, UInt8(frequency)])
    }

    /// Machine gun: vibration alternating between `amplitudeA` and `amplitudeB` (0–7)
    /// every `period` (tenths of a second) between `start` (1–8) and `end`. UNOFFICIAL.
    public static func machine(start: Int, end: Int, amplitudeA: Int, amplitudeB: Int, frequency: Int, period: Int)
        throws(ValidationError) -> TriggerEffect
    {
        try check("start", start, 1...8)
        try check("end", end, 0...9)
        guard end > start else { throw .ordering("end must be > start") }
        try check("amplitudeA", amplitudeA, 0...7)
        try check("amplitudeB", amplitudeB, 0...7)
        try check("frequency", frequency, 0...255)
        try check("period", period, 0...255)
        guard frequency > 0 else { return .off }
        let zones: UInt16 = (1 << start) | (1 << end)
        let pair = UInt8(amplitudeA & 7) | UInt8(amplitudeB & 7) << 3
        return TriggerEffect(rawBytes: [Mode.machine.rawValue] + zonesBytes(zones) + [pair, UInt8(frequency), UInt8(period)])
    }
}
