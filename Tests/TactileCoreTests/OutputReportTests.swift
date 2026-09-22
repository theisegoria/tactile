import Testing
@testable import TactileCore

// Vectors: tools/gen_vectors.py from the documented common-block layout.
// State: rumble L=0x40 R=0x20, right trigger weapon(2,6,8), lightbar #FF0080,
// player 2 LEDs, mute LED on.
let btOutV2Seq0 = hex("31 00 10 06 15 20 40 00 00 00 00 01 00 25 44 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 00 0a ff 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 48 22 94 6a")
let btOutLegacySeq5 = hex("31 50 10 07 15 20 40 00 00 00 00 01 00 25 44 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0a ff 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 20 9f d9 3c")
let usbOut = hex("02 06 15 20 40 00 00 00 00 01 00 25 44 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 00 0a ff 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")

@Suite struct OutputReportTests {
    func sampleState() throws -> OutputState {
        OutputState(
            rumble: Rumble(left: 0x40, right: 0x20),
            rightTrigger: try .weapon(start: 2, end: 6, strength: 8),
            lightbar: LightbarColor(red: 0xFF, green: 0, blue: 0x80),
            playerLEDs: .player(2),
            muteLED: .on)
    }

    @Test func bluetoothVibrationV2() throws {
        var b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        let r = b.build(try sampleState(), transport: .bluetooth)
        #expect(r == btOutV2Seq0)
        #expect(CRC32.verify(r, prefix: .output))
        #expect(b.sequence == 1)
    }

    @Test func bluetoothLegacySequenceWraps() throws {
        var b = OutputReportBuilder(features: FeatureSet(vibrationV2: false, hasEdgeButtons: false))
        for _ in 0..<5 { _ = b.build(OutputState(), transport: .bluetooth) }
        #expect(b.build(try sampleState(), transport: .bluetooth) == btOutLegacySeq5)
        for _ in 0..<10 { _ = b.build(OutputState(), transport: .bluetooth) }
        #expect(b.sequence == 0)
    }

    @Test func usb() throws {
        var b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        #expect(b.build(try sampleState(), transport: .usb) == usbOut)
        #expect(b.sequence == 0)  // USB does not consume Bluetooth sequence numbers
    }

    @Test func uncontrolledFieldsLeaveFlagsClear() {
        let b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        let c = b.encodeCommon(OutputState(lightbar: .off))
        #expect(c[OutputLayout.validFlag0] == 0)
        #expect(c[OutputLayout.validFlag1] == OutputLayout.flag1Lightbar)
        #expect(c[OutputLayout.validFlag2] == 0)
    }

    @Test func neutralState() {
        let b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        let c = b.encodeCommon(.neutral())
        #expect(c[OutputLayout.validFlag0] == OutputLayout.flag0HapticsSelect | OutputLayout.flag0LeftTrigger | OutputLayout.flag0RightTrigger)
        #expect(c[OutputLayout.rightTrigger] == TriggerEffect.Mode.off.rawValue)
        #expect(c[OutputLayout.leftTrigger] == TriggerEffect.Mode.off.rawValue)
        #expect(c[OutputLayout.motorLeft] == 0 && c[OutputLayout.motorRight] == 0)
    }

    @Test func micMuteAndLightbarRelease() {
        let b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        let c = b.encodeCommon(OutputState(micMuted: true, releaseLightbarAnimation: true))
        #expect(c[OutputLayout.validFlag1] == OutputLayout.flag1PowerSave)
        #expect(c[OutputLayout.powerSaveControl] == 0x10)
        #expect(c[OutputLayout.validFlag2] == OutputLayout.flag2LightbarSetup)
        #expect(c[OutputLayout.lightbarSetup] == 0x02)
    }

    @Test func merging() {
        let a = OutputState(rumble: .off, lightbar: .off)
        let m = a.merging(OutputState(lightbar: LightbarColor(red: 1, green: 2, blue: 3), muteLED: .pulse))
        #expect(m.rumble == .off)
        #expect(m.lightbar == LightbarColor(red: 1, green: 2, blue: 3))
        #expect(m.muteLED == .pulse)
    }

    @Test func playerPatterns() {
        #expect((1...5).map { PlayerLEDs.player($0).rawValue } == [0x04, 0x0A, 0x15, 0x1B, 0x1F])
        #expect(PlayerLEDs.player(9) == .none)
        #expect(LightbarColor(hex: "#ff0080") == LightbarColor(red: 255, green: 0, blue: 128))
        #expect(LightbarColor(hex: "zz") == nil)
    }
}
