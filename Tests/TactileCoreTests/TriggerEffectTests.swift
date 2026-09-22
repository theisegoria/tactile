import Testing
@testable import TactileCore

// Vectors: hand-derived from the formulas in Nielk1's TriggerEffectGenerator gist
// (MIT); multi-zone vectors computed by tools/gen_vectors.py.
@Suite struct TriggerEffectTests {
    @Test func off() {
        #expect(TriggerEffect.off.bytes == hex("05 00 00 00 00 00 00 00 00 00 00"))
        #expect(TriggerEffect.off.mode == .off)
    }

    @Test func feedback() throws {
        #expect(try TriggerEffect.feedback(position: 3, strength: 5).bytes == hex("21 f8 03 00 48 92 24 00 00 00 00"))
        #expect(try TriggerEffect.feedback(position: 0, strength: 0) == .off)
    }

    @Test func weapon() throws {
        #expect(try TriggerEffect.weapon(start: 2, end: 6, strength: 8).bytes == hex("25 44 00 07 00 00 00 00 00 00 00"))
        #expect(throws: TriggerEffect.ValidationError.self) { try TriggerEffect.weapon(start: 1, end: 6, strength: 8) }
        #expect(throws: TriggerEffect.ValidationError.self) { try TriggerEffect.weapon(start: 5, end: 5, strength: 8) }
    }

    @Test func vibration() throws {
        #expect(try TriggerEffect.vibration(position: 0, amplitude: 8, frequency: 40).bytes
            == hex("26 ff 03 ff ff ff 3f 00 00 28 00"))
        #expect(try TriggerEffect.vibration(position: 0, amplitude: 8, frequency: 0) == .off)
    }

    @Test func slopeFeedback() throws {
        #expect(try TriggerEffect.slopeFeedback(startPosition: 0, endPosition: 9, startStrength: 1, endStrength: 8).bytes
            == hex("21 ff 03 88 34 b6 3e 00 00 00 00"))
        // 2.5 must round to 2 (half-to-even), as C# Math.Round does in the reference.
        #expect(try TriggerEffect.slopeFeedback(startPosition: 0, endPosition: 4, startStrength: 2, endStrength: 3).bytes
            == hex("21 ff 03 49 24 49 12 00 00 00 00"))
        #expect(try TriggerEffect.slopeFeedback(startPosition: 2, endPosition: 6, startStrength: 8, endStrength: 1).bytes
            == hex("21 fc 03 c0 3b 01 00 00 00 00 00"))
    }

    @Test func multiplePositionVibration() throws {
        let e = try TriggerEffect.multiplePositionVibration(frequency: 10, amplitudes: [1, 0, 0, 0, 0, 0, 0, 0, 0, 8])
        #expect(e.bytes == hex("26 01 02 00 00 00 38 00 00 0a 00"))
    }

    @Test func bow() throws {
        #expect(try TriggerEffect.bow(start: 1, end: 5, strength: 8, snapForce: 8).bytes == hex("22 22 00 3f 00 00 00 00 00 00 00"))
        #expect(throws: TriggerEffect.ValidationError.self) { try TriggerEffect.bow(start: 5, end: 5, strength: 1, snapForce: 1) }
    }

    @Test func galloping() throws {
        #expect(try TriggerEffect.galloping(start: 0, end: 9, firstFoot: 4, secondFoot: 7, frequency: 5).bytes
            == hex("23 01 02 27 05 00 00 00 00 00 00"))
        #expect(throws: TriggerEffect.ValidationError.self) {
            try TriggerEffect.galloping(start: 0, end: 9, firstFoot: 7, secondFoot: 7, frequency: 5)
        }
    }

    @Test func machine() throws {
        #expect(try TriggerEffect.machine(start: 1, end: 9, amplitudeA: 3, amplitudeB: 7, frequency: 5, period: 3).bytes
            == hex("27 02 02 3b 05 03 00 00 00 00 00"))
        #expect(throws: TriggerEffect.ValidationError.self) {
            try TriggerEffect.machine(start: 0, end: 9, amplitudeA: 3, amplitudeB: 7, frequency: 5, period: 3)
        }
    }

    @Test func officialFlags() {
        #expect(TriggerEffect.Mode.allCases.filter(\.isOfficial) == [.off, .feedback, .weapon, .vibration])
    }

    @Test func rawBytesPadded() {
        #expect(TriggerEffect(rawBytes: [0xFC, 1]).bytes.count == 11)
    }
}
