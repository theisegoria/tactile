// Parametric haptic effects for game events, synthesised directly at 3 kHz.
// Voice-coil actuators respond best roughly between 50 and 400 Hz; every
// effect stays well under the 1.5 kHz Nyquist limit.

import Foundation

/// Which actuator(s) an effect drives. Channel 0 = left grip, 1 = right grip
/// (UNVERIFIED channel mapping, see TESTING.md).
public enum HapticSide: String, Sendable, Codable, CaseIterable {
    case left, right, both
}

/// A parametric effect. All intensities are 0…1.
public enum HapticEffect: Sendable, Hashable, Codable {
    /// A crisp tick (UI click, weapon dry-fire).
    case click(intensity: Float = 1, frequency: Float = 250)
    /// A softer notch, like a rotary detent.
    case detent(intensity: Float = 0.7, frequency: Float = 170)
    /// A continuous grainy surface, `grainRate` grains per second.
    /// `duration` is clamped to 0…`HapticEffect.maximumDuration` (NaN plays nothing).
    case texture(intensity: Float = 0.5, grainRate: Float = 60, duration: Double = 0.5)
    /// A heavy thump with a noisy transient (landing, collision).
    case impact(intensity: Float = 1)
    /// A pure tone for `duration` seconds, clamped to 0…`HapticEffect.maximumDuration`
    /// (so `.infinity` holds until `stopAll()`, up to that cap; NaN plays nothing).
    case tone(intensity: Float, frequency: Float, duration: Double)

    /// Longest effect a voice will play, in seconds (one hour).
    public static let maximumDuration: Double = 3600

    public var duration: Double {
        switch self {
        case .click: 0.012
        case .detent: 0.025
        case .texture(_, _, let d): d
        case .impact: 0.12
        case .tone(_, _, let d): d
        }
    }
}

/// One playing effect instance. Renders mono samples at `sampleRate`.
struct Voice: Sendable {
    let effect: HapticEffect
    let side: HapticSide
    let sampleRate: Float
    let length: Int
    var position = 0
    var rng: XorShift32
    var nextGrain = 0
    var grainStart = 0

    init(effect: HapticEffect, side: HapticSide, sampleRate: Float, seed: UInt32) {
        self.effect = effect
        self.side = side
        self.sampleRate = sampleRate
        // Clamp before converting: Int() traps on NaN, infinity and huge values.
        let d = effect.duration
        let seconds = d.isNaN ? 0 : min(max(d, 0), HapticEffect.maximumDuration)
        let rate = sampleRate.isFinite ? max(Double(sampleRate), 0) : 0
        length = max(1, Int(seconds * rate))
        rng = XorShift32(seed: seed)
    }

    var finished: Bool { position >= length }

    mutating func next() -> Float {
        defer { position += 1 }
        guard position < length else { return 0 }
        let t = Float(position) / sampleRate
        switch effect {
        case .click(let a, let f):
            // ~1.5 cycles with a fast exponential decay.
            return a * sin(2 * .pi * f * t) * exp(-t / 0.004)
        case .detent(let a, let f):
            // Raised-cosine envelope, smooth onset.
            let env = 0.5 - 0.5 * cos(2 * .pi * Float(position) / Float(length))
            return a * env * sin(2 * .pi * f * t)
        case .texture(let a, let rate, _):
            // Short decaying 200 Hz grains at jittered intervals.
            // Each grain starts at its own onset (zero phase, full level), so
            // every grain has the same shape whatever its jittered spacing.
            if position >= nextGrain {
                let interval = sampleRate / (rate.isNaN ? 1 : max(rate, 1))  // Int() below traps on NaN
                grainStart = position
                nextGrain = position + max(1, Int(interval * (0.6 + 0.8 * (rng.unit() + 0.5))))
            }
            let sinceGrain = Float(position - grainStart) / sampleRate
            return a * 0.8 * sin(2 * .pi * 200 * sinceGrain) * exp(-sinceGrain / 0.006)
        case .impact(let a):
            let body = sin(2 * .pi * 70 * t) * exp(-t / 0.045)
            let transient = rng.unit() * 2 * exp(-t / 0.006)
            return a * (0.85 * body + 0.35 * transient)
        case .tone(let a, let f, _):
            let fade = min(1, Float(position) / 15, Float(length - position) / 15)
            return a * fade * sin(2 * .pi * f * t)
        }
    }
}
