import Foundation
import Testing
@testable import TactileCore

@Suite struct TriggerCurveTests {
    static let allSpecs: [TriggerEffectSpec] = [
        .off,
        .feedback(position: 3, strength: 5),
        .multiplePositionFeedback(strengths: [0, 1, 2, 3, 4, 5, 6, 7, 8, 0]),
        .slopeFeedback(startPosition: 0, endPosition: 9, startStrength: 1, endStrength: 8),
        .weapon(start: 2, end: 6, strength: 8),
        .vibration(position: 0, amplitude: 8, frequency: 40),
        .multiplePositionVibration(frequency: 30, amplitudes: [8, 7, 6, 5, 4, 3, 2, 1, 0, 0]),
        .bow(start: 1, end: 6, strength: 6, snapForce: 8),
        .galloping(start: 0, end: 9, firstFoot: 2, secondFoot: 5, frequency: 3),
        .machine(start: 1, end: 9, amplitudeA: 7, amplitudeB: 3, frequency: 9, period: 2),
        .raw(bytes: [0x99, 1, 2]),
    ]

    @Test func decodingReproducesBytes() throws {
        for spec in Self.allSpecs {
            let effect = try spec.effect()
            let decoded = TriggerEffectSpec(decoding: effect)
            #expect(try decoded.effect().bytes == effect.bytes, "\(spec)")
        }
        // Single-position forms decode to their multiple-position equivalents.
        #expect(TriggerEffectSpec(decoding: try .feedback(position: 3, strength: 5))
            == .multiplePositionFeedback(strengths: [0, 0, 0, 5, 5, 5, 5, 5, 5, 5]))
        #expect(TriggerEffectSpec(decoding: try .weapon(start: 2, end: 6, strength: 8)) == .weapon(start: 2, end: 6, strength: 8))
        #expect(TriggerEffectSpec(decoding: .off) == .off)
        // Stray bytes that no factory writes stay raw.
        var b = try TriggerEffect.weapon(start: 2, end: 6, strength: 8).bytes
        b[10] = 1
        #expect(TriggerEffectSpec(decoding: TriggerEffect(rawBytes: b)) == .raw(bytes: b))
    }

    @Test func specJSONRoundTrip() throws {
        for spec in Self.allSpecs {
            let data = try JSONEncoder().encode(spec)
            #expect(try JSONDecoder().decode(TriggerEffectSpec.self, from: data) == spec.normalizedRaw)
        }
        let weapon = try JSONEncoder.sorted.encode(TriggerEffectSpec.weapon(start: 2, end: 6, strength: 8))
        #expect(String(decoding: weapon, as: UTF8.self) == #"{"end":6,"start":2,"strength":8,"type":"weapon"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TriggerEffectSpec.self, from: Data(#"{"type":"laser"}"#.utf8))
        }
    }

    @Test func feedbackCurve() throws {
        let c = TriggerEffectSpec.feedback(position: 3, strength: 4).curve
        #expect(c.sample(at: 0).resistance == 0)
        #expect(c.sample(at: 0.29).resistance == 0)
        #expect(c.sample(at: 0.3).resistance == 0.5)
        #expect(c.sample(at: 1).resistance == 0.5)
        #expect(c.sample(at: 1).amplitude == 0)
        #expect(c.releasePosition == nil)
    }

    @Test func slopeCurveRises() {
        let s = TriggerPreset.brakePedal.curve.samples(count: 10)
        for (a, b) in zip(s, s.dropFirst()) { #expect(b.resistance >= a.resistance) }
        #expect(s.first?.resistance == 0.125)
        #expect(s.last?.resistance == 1)
    }

    @Test func weaponBreaks() {
        let c = TriggerEffectSpec.weapon(start: 2, end: 6, strength: 8).curve
        #expect(c.sample(at: 0.1).resistance == 0)
        #expect(c.sample(at: 0.25).resistance == 1)
        #expect(c.sample(at: 0.55).resistance == 1)
        #expect(c.sample(at: 0.65).resistance == 0)
        #expect(c.releasePosition == 0.6)
    }

    @Test func bowSnapsBack() {
        let c = TriggerPreset.bowDraw.curve
        #expect(c.sample(at: 0).resistance == 0)
        #expect(c.sample(at: 0.3).resistance == 0.75)
        #expect(c.sample(at: 0.8).resistance == 1)  // snap force 8
    }

    @Test func vibrationCurves() {
        let v = TriggerEffectSpec.vibration(position: 5, amplitude: 4, frequency: 40).curve
        #expect(v.sample(at: 0.2).amplitude == 0)
        #expect(v.sample(at: 0.2).frequency == 0)
        #expect(v.sample(at: 0.7).amplitude == 0.5)
        #expect(v.sample(at: 0.7).frequency == 40)
        #expect(v.sample(at: 0.7).resistance == 0)

        let m = TriggerPreset.machineGun.curve
        #expect(m.sample(at: 0.5).amplitude == 1)                 // peak envelope
        #expect(m.sample(at: 0.5, time: 0.1).amplitude == 1)      // first period: A = 7/7
        #expect(abs(m.sample(at: 0.5, time: 0.3).amplitude - 3.0 / 7) < 1e-9)  // second period: B
        #expect(m.sample(at: 0.05).amplitude == 0)                // before start zone 1

        let g = TriggerPreset.gallop.curve
        #expect(g.frequency == 3)
        // Feet at phases 2/8 and 5/8 of a 1/3 s cycle.
        #expect(g.sample(at: 0.5, time: (2.0 / 8 + 0.01) / 3).amplitude == 1)
        #expect(g.sample(at: 0.5, time: (4.0 / 8) / 3).amplitude == 0)
    }

    @Test func offAndRawAreFlat() {
        #expect(TriggerEffect.off.curve.isFlat)
        #expect(TriggerEffectSpec.raw(bytes: [0x99]).curve.isFlat)
        #expect(TriggerEffectSpec.weapon(start: 0, end: 1, strength: 1).curve.isFlat)  // invalid spec → off
        #expect(!TriggerPreset.weaponTrigger.curve.isFlat)
    }

    @Test func zoneMappingClamps() {
        #expect(TriggerCurve.zone(for: -1) == 0)
        #expect(TriggerCurve.zone(for: .nan) == 0)
        #expect(TriggerCurve.zone(for: 0.95) == 9)
        #expect(TriggerCurve.zone(for: 1) == 9)
        #expect(TriggerCurve.zone(for: 5) == 9)
        #expect(TriggerPreset.off.curve.samples(count: 0).count == 2)
    }

    @Test func presetsAreValidAndDistinct() throws {
        var seen = Set<[UInt8]>()
        for p in TriggerPreset.allCases {
            let e = try p.spec.effect()
            #expect(seen.insert(e.bytes).inserted, "\(p)")
            #expect(p.effect == e)
            #expect(!p.displayName.isEmpty)
        }
        #expect(TriggerPreset.off.effect == .off)
        #expect(TriggerPreset.weaponTrigger.effect.mode == .weapon)
        #expect(TriggerPreset.machineGun.effect.mode == .machine)
        #expect(TriggerPreset.gallop.effect.mode == .galloping)
        #expect(TriggerPreset.bowDraw.effect.mode == .bow)
    }
}

extension TriggerEffectSpec {
    /// Raw bytes are padded to 11 when encoded.
    var normalizedRaw: TriggerEffectSpec {
        if case .raw(let b) = self { return .raw(bytes: TriggerEffect(rawBytes: b).bytes) }
        return self
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
