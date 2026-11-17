// Force curves for drawing trigger effects: resistance and vibration as a
// function of trigger travel. Pure, built from the 11 wire bytes, so a curve
// always shows what the controller is actually sent.
//
// The firmware divides travel into 10 zones (0 = released … 9 = fully pulled).
// Zone semantics follow Nielk1's TriggerEffectGenerator notes. How the
// firmware shapes force inside a zone, and the exact feel of the unofficial
// effects, are NOT measured: the curves are a faithful rendering of the
// parameters, not a force-gauge recording (UNVERIFIED on hardware).

/// One point on a trigger curve.
public struct TriggerCurveSample: Sendable, Hashable {
    /// Trigger travel, 0 (released) … 1 (fully pulled).
    public var position: Double
    /// Resisting force, 0…1 (firmware strength / 8). For a bow effect, past
    /// the release point this is the snap-back force.
    public var resistance: Double
    /// Vibration amplitude, 0…1 (firmware amplitude / 8, or / 7 for machine).
    public var amplitude: Double
    /// Vibration frequency in Hz (0 when not vibrating). For galloping this is
    /// the gallop cycle rate.
    public var frequency: Double

    public init(position: Double, resistance: Double, amplitude: Double, frequency: Double) {
        self.position = position
        self.resistance = resistance
        self.amplitude = amplitude
        self.frequency = frequency
    }
}

/// Resistance/vibration over trigger travel for one effect.
public struct TriggerCurve: Sendable, Hashable {
    public static let zoneCount = 10

    /// The decoded effect the curve describes.
    public let spec: TriggerEffectSpec
    /// Per-zone resisting force 0…1.
    public let zoneResistance: [Double]
    /// Per-zone vibration amplitude envelope 0…1 (the peak for time-varying effects).
    public let zoneAmplitude: [Double]
    /// Vibration frequency in Hz (0 if none).
    public let frequency: Double
    /// Where a weapon trigger breaks or a bow releases (0…1), else nil.
    public let releasePosition: Double?

    private enum Modulation: Hashable, Sendable {
        case none
        /// Machine: amplitude alternates a ↔ b every `period` seconds.
        case alternate(a: Double, b: Double, period: Double)
        /// Galloping: two short pulses per cycle at these cycle phases.
        case feet(Double, Double)
    }
    private let modulation: Modulation

    /// The zone (0…9) containing `position` (clamped to 0…1).
    public static func zone(for position: Double) -> Int {
        let p = position.isNaN ? 0 : min(max(position, 0), 1)
        return min(zoneCount - 1, Int(p * Double(zoneCount)))
    }

    public init(effect: TriggerEffect) {
        self.init(decoded: TriggerEffectSpec(decoding: effect))
    }

    /// The curve of what `spec` encodes to; an invalid spec gives the off curve.
    public init(spec: TriggerEffectSpec) {
        self.init(effect: (try? spec.effect()) ?? .off)
    }

    private init(decoded spec: TriggerEffectSpec) {
        self.spec = spec
        var r = [Double](repeating: 0, count: Self.zoneCount)
        var a = [Double](repeating: 0, count: Self.zoneCount)
        var freq = 0.0
        var release: Double?
        var mod = Modulation.none
        func clampZone(_ z: Int) -> Int { min(max(z, 0), Self.zoneCount - 1) }
        switch spec {
        case .off, .raw:
            break
        case let .multiplePositionFeedback(s):
            for i in 0..<min(s.count, Self.zoneCount) { r[i] = Double(s[i]) / 8 }
        case let .multiplePositionVibration(f, amps):
            for i in 0..<min(amps.count, Self.zoneCount) { a[i] = Double(amps[i]) / 8 }
            freq = Double(f)
        case let .weapon(start, end, strength):
            for i in clampZone(start)..<clampZone(end) { r[i] = Double(strength) / 8 }
            release = Double(end) / Double(Self.zoneCount)
        case let .bow(start, end, strength, snap):
            for i in 0..<Self.zoneCount where i >= start {
                r[i] = i < end ? Double(strength) / 8 : Double(snap) / 8
            }
            release = Double(end) / Double(Self.zoneCount)
        case let .galloping(start, end, f1, f2, f):
            for i in clampZone(start)...clampZone(end) { a[i] = 1 }
            freq = Double(f)
            mod = .feet(Double(f1) / 8, Double(f2) / 8)
        case let .machine(start, end, ampA, ampB, f, period):
            let peak = Double(max(ampA, ampB)) / 7
            for i in clampZone(start)...clampZone(end) { a[i] = peak }
            freq = Double(f)
            mod = .alternate(a: Double(ampA) / 7, b: Double(ampB) / 7, period: Double(period) / 10)
        case .feedback, .slopeFeedback, .vibration:
            break  // decoding yields the multiple-position forms instead
        }
        zoneResistance = r
        zoneAmplitude = a
        frequency = freq
        releasePosition = release
        modulation = mod
    }

    /// The curve at `position` (0…1). With `time` (seconds since the effect
    /// started) the amplitude of time-varying effects (machine, galloping) is
    /// the instantaneous envelope; without it, the peak.
    public func sample(at position: Double, time: Double? = nil) -> TriggerCurveSample {
        let z = Self.zone(for: position)
        var amp = zoneAmplitude[z]
        if amp > 0, let t = time, t.isFinite {
            switch modulation {
            case .none: break
            case let .alternate(a, b, period):
                if period > 0 {
                    amp = Int((max(t, 0) / period).rounded(.down)) % 2 == 0 ? a : b
                } else {
                    amp = a
                }
            case let .feet(p1, p2):
                guard frequency > 0 else { amp = 0; break }
                let phase = (max(t, 0) * frequency).truncatingRemainder(dividingBy: 1)
                let width = 1.0 / 16
                let onFoot = (phase >= p1 && phase < p1 + width) || (phase >= p2 && phase < p2 + width)
                amp = onFoot ? amp : 0
            }
        }
        let clamped = position.isNaN ? 0 : min(max(position, 0), 1)
        return TriggerCurveSample(position: clamped, resistance: zoneResistance[z], amplitude: amp,
                                  frequency: amp > 0 || zoneAmplitude[z] > 0 ? frequency : 0)
    }

    /// `count` evenly spaced samples from 0 to 1 inclusive (at least 2).
    public func samples(count: Int = 101, time: Double? = nil) -> [TriggerCurveSample] {
        let n = max(2, count)
        return (0..<n).map { sample(at: Double($0) / Double(n - 1), time: time) }
    }

    /// True when the effect neither resists nor vibrates anywhere.
    public var isFlat: Bool { zoneResistance.allSatisfy { $0 == 0 } && zoneAmplitude.allSatisfy { $0 == 0 } }
}

extension TriggerEffect {
    /// Resistance/vibration over trigger travel, for drawing.
    public var curve: TriggerCurve { TriggerCurve(effect: self) }
}

extension TriggerEffectSpec {
    /// Resistance/vibration over trigger travel of what this spec encodes to.
    public var curve: TriggerCurve { TriggerCurve(spec: self) }
}

// MARK: Presets

/// Named starting points built from the existing factories.
public enum TriggerPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    case off
    /// A gun trigger: resistance that breaks partway down.
    case weaponTrigger
    /// Drawing a bow: steady tension, then a snap when released. UNOFFICIAL effect.
    case bowDraw
    /// A brake pedal: resistance rising linearly with travel.
    case brakePedal
    /// A short, sharp click partway down (a narrow weapon break).
    case clickDetent
    /// Automatic fire: alternating vibration while pulled. UNOFFICIAL effect.
    case machineGun
    /// A galloping horse: two taps per cycle. UNOFFICIAL effect.
    case gallop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .weaponTrigger: "Weapon trigger"
        case .bowDraw: "Bow draw"
        case .brakePedal: "Brake pedal"
        case .clickDetent: "Click / detent"
        case .machineGun: "Machine gun"
        case .gallop: "Gallop"
        }
    }

    public var spec: TriggerEffectSpec {
        switch self {
        case .off: .off
        case .weaponTrigger: .weapon(start: 2, end: 6, strength: 8)
        case .bowDraw: .bow(start: 1, end: 6, strength: 6, snapForce: 8)
        case .brakePedal: .slopeFeedback(startPosition: 0, endPosition: 9, startStrength: 1, endStrength: 8)
        case .clickDetent: .weapon(start: 4, end: 5, strength: 8)
        case .machineGun: .machine(start: 1, end: 9, amplitudeA: 7, amplitudeB: 3, frequency: 9, period: 2)
        case .gallop: .galloping(start: 0, end: 9, firstFoot: 2, secondFoot: 5, frequency: 3)
        }
    }

    /// The wire effect. Preset parameters are valid by construction.
    public var effect: TriggerEffect { (try? spec.effect()) ?? .off }

    public var curve: TriggerCurve { TriggerCurve(spec: spec) }
}
