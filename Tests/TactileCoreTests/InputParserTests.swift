import Testing
@testable import TactileCore

// Vectors: synthesised from the documented layout by tools/gen_vectors.py
// (sticks 10/20/30/40, L2 50, R2 60, seq 7, cross + dpad right, L1 + options,
// PS + mute, gyro 1/-2/3, accel 100/-200/8192, ts 0x01020304, touch0 id 5 at
// (1000, 500), touch1 inactive, status 0x18, headphones plugged).
let btInFull = hex("31 00 0a 14 1e 28 32 3c 07 22 21 05 00 00 00 00 00 01 00 fe ff 03 00 64 00 38 ff 00 20 04 03 02 01 00 05 e8 43 1f 83 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 5b 2c 66")
let btInEdge = hex("31 00 0a 14 1e 28 32 3c 07 22 21 f5 00 00 00 00 00 01 00 fe ff 03 00 64 00 38 ff 00 20 04 03 02 01 00 05 e8 43 1f 83 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 29 91 05 0d")
let usbIn = hex("01 0a 14 1e 28 32 3c 07 22 21 05 00 00 00 00 00 01 00 fe ff 03 00 64 00 38 ff 00 20 04 03 02 01 00 05 e8 43 1f 83 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18 01 00 00 00 00 00 00 00 00 00")

@Suite struct InputParserTests {
    func checkCommon(_ s: InputState) {
        #expect(s.leftStick == SIMD2(10, 20))
        #expect(s.rightStick == SIMD2(30, 40))
        #expect(s.l2 == 50 && s.r2 == 60)
        #expect(s.sequence == 7)
        #expect(s.buttons.isSuperset(of: [.cross, .dpadRight, .l1, .options, .ps, .mute]))
        #expect(!s.buttons.contains(.dpadUp))
        #expect(s.imu == RawIMU(gyro: SIMD3(1, -2, 3), accel: SIMD3(100, -200, 8192), timestamp: 0x0102_0304))
        #expect(s.touchPoints.count == 2)
        #expect(s.touchPoints[0] == TouchPoint(active: true, id: 5, x: 1000, y: 500))
        #expect(s.touchPoints[1].active == false)
        #expect(s.touchPoints[1].id == 3)
        #expect(s.battery == BatteryStatus(percent: 85, charging: .charging))
        #expect(s.headphonesConnected == true)
        #expect(s.micConnected == false)
    }

    @Test func bluetoothFull() throws {
        let s = try InputParser.parse(btInFull, transport: .bluetooth, model: .dualSense)
        #expect(s.kind == .bluetoothFull)
        checkCommon(s)
        #expect(s.buttons.intersection([.fnLeft, .fnRight, .paddleLeft, .paddleRight]).isEmpty)
    }

    @Test func usbFull() throws {
        let s = try InputParser.parse(usbIn, transport: .usb, model: .dualSense)
        #expect(s.kind == .usbFull)
        checkCommon(s)
    }

    @Test func edgeButtonsOnlyDecodedForEdge() throws {
        let edge = try InputParser.parse(btInEdge, transport: .bluetooth, model: .dualSenseEdge)
        #expect(edge.buttons.isSuperset(of: [.fnLeft, .fnRight, .paddleLeft, .paddleRight]))
        let plain = try InputParser.parse(btInEdge, transport: .bluetooth, model: .dualSense)
        #expect(plain.buttons.intersection([.fnLeft, .fnRight, .paddleLeft, .paddleRight]).isEmpty)
    }

    @Test func badCRCRejected() {
        var r = btInFull
        r[5] ^= 0xFF
        #expect(throws: ParseError.badCRC(reportID: 0x31)) {
            try InputParser.parse(r, transport: .bluetooth, model: .dualSense)
        }
        // …unless verification is disabled.
        #expect((try? InputParser.parse(r, transport: .bluetooth, model: .dualSense, verifyCRC: false)) != nil)
    }

    // Source: SDL simple-state layout (ucLeftJoystickX…ucTriggerRight). Buttons byte 7
    // carries a counter in its high 6 bits, which must not leak into mute/Edge bits.
    @Test func bluetoothReduced() throws {
        let r = hex("01 80 7f 01 ff 1f 02 fd 10 f0")
        let s = try InputParser.parse(r, transport: .bluetooth, model: .dualSenseEdge)
        #expect(s.kind == .bluetoothReduced)
        #expect(s.leftStick == SIMD2(0x80, 0x7F))
        #expect(s.rightStick == SIMD2(0x01, 0xFF))
        #expect(s.buttons == [.square, .dpadUp, .r1, .ps])
        #expect(s.l2 == 0x10 && s.r2 == 0xF0)
        #expect(s.imu == nil && s.battery == nil)
    }

    @Test func dpadDecoding() {
        #expect(Buttons.dpad(hat: 8) == [])
        #expect(Buttons.dpad(hat: 7) == [.dpadUp, .dpadLeft])
        #expect(Buttons.dpad(hat: 3) == [.dpadDown, .dpadRight])
    }

    @Test func errors() {
        #expect(throws: ParseError.empty) { try InputParser.parse([], transport: .usb, model: .dualSense) }
        #expect(throws: ParseError.unknownReportID(0x42)) { try InputParser.parse([0x42, 0], transport: .usb, model: .dualSense) }
        #expect(throws: ParseError.tooShort(reportID: 0x31, expected: 78, actual: 10)) {
            try InputParser.parse([0x31] + [UInt8](repeating: 0, count: 9), transport: .bluetooth, model: .dualSense)
        }
    }

    @Test func batteryStatus() {
        #expect(BatteryStatus(statusByte: 0x0A) == BatteryStatus(percent: 100, charging: .discharging))
        #expect(BatteryStatus(statusByte: 0x00) == BatteryStatus(percent: 5, charging: .discharging))
        #expect(BatteryStatus(statusByte: 0x2F).charging == .full)
        #expect(BatteryStatus(statusByte: 0x2F).percent == 100)
        #expect(BatteryStatus(statusByte: 0xF0).charging == .error)
    }
}
