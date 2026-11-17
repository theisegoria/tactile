import Foundation
import Synchronization
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport

/// USB (report 0x01 in, 0x02 out) at the connection level, without hardware.
/// The byte layouts come from the same common block as Bluetooth (PROTOCOL.md);
/// the USB-specific facts asserted here are framing facts (report IDs, lengths,
/// no CRC, no sequence). Whether the USB firmware needs the lightbar-release
/// step that Bluetooth needs is UNVERIFIED (the library sends it on Bluetooth only).
final class ReportLog: Sendable {
    let reports = Mutex<[[UInt8]]>([])
    var last: [UInt8]? { reports.withLock { $0.last } }
}

@Suite struct USBTransportTests {
    func usbConnection(_ log: ReportLog) -> DeviceConnection {
        DeviceConnection(info: device(7, transport: .usb), options: testOptions(),
                         io: ConnectionIO(send: { r in log.reports.withLock { $0.append(r) } }))
    }

    @Test func outputReportIs0x02WithCommonBlockAtOffset1() async throws {
        let log = ReportLog()
        let c = usbConnection(log)
        let weapon = try TriggerEffect.weapon(start: 2, end: 6, strength: 8)
        try await c.apply(OutputState(rumble: Rumble(left: 9, right: 7), rightTrigger: weapon,
                                      lightbar: LightbarColor(red: 1, green: 2, blue: 3), playerLEDs: .player(1)))
        let r = try #require(log.last)
        #expect(r.count == OutputLayout.usbLength)
        #expect(r[0] == 0x02)
        let base = 1
        #expect(r[base + OutputLayout.motorLeft] == 9)
        #expect(r[base + OutputLayout.motorRight] == 7)
        #expect(Array(r[(base + OutputLayout.rightTrigger)..<(base + OutputLayout.rightTrigger + 11)]) == weapon.bytes)
        #expect(Array(r[(base + OutputLayout.lightbarRed)...(base + OutputLayout.lightbarRed + 2)]) == [1, 2, 3])
        #expect(r[base + OutputLayout.playerLEDs] & 0x1F == PlayerLEDs.player(1).rawValue)
        // Lightbar release (valid_flag2 bit 1) is a Bluetooth-only step here.
        #expect(r[base + OutputLayout.validFlag2] & OutputLayout.flag2LightbarSetup == 0)
        await c.close()
    }

    @Test func usbReportsCarryNoSequenceOrCRC() {
        var b = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))
        let s = OutputState(lightbar: LightbarColor(red: 5, green: 6, blue: 7))
        let first = b.build(s, transport: .usb)
        let second = b.build(s, transport: .usb)
        #expect(first == second)                 // nothing changes between reports
        #expect(first.suffix(10).allSatisfy { $0 == 0 })  // no trailing CRC
    }

    @Test func featureReportsAreNotCRCStrippedOnUSB() throws {
        let raw: [UInt8] = [0x05] + (1...40).map { UInt8($0) }
        #expect(try FeatureReportFraming.decode(raw, reportID: 0x05, expectedLength: 41, transport: .usb) == raw)
        // An ID-less buffer gets its report ID back.
        #expect(try FeatureReportFraming.decode(Array(raw.dropFirst()), reportID: 0x05, expectedLength: 41, transport: .usb) == raw)
        #expect(try FeatureReportFraming.unwrap([0x09, 1, 2], transport: .usb) == [0x09, 1, 2])
    }

    @Test func usbInputParsesFullState() throws {
        let report: [UInt8] = [0x01] + [UInt8](repeating: 0, count: 63)
        var r = report
        r[1] = 0x10; r[2] = 0xF0; r[5] = 0x40; r[6] = 0xC0  // sticks, L2
        let s = try InputParser.parse(r, transport: .usb, model: .dualSense)
        #expect(s.kind == .usbFull)
        #expect(s.leftStick == SIMD2(0x10, 0xF0))
        #expect(s.l2 == 0x40 && s.r2 == 0xC0)
        #expect(s.imu != nil)
        #expect(throws: ParseError.self) { try InputParser.parse(Array(r.prefix(20)), transport: .usb, model: .dualSense) }
    }

    @Test func audioHapticsAreRefusedOverUSB() async throws {
        let log = ReportLog()
        let connection = usbConnection(log)
        let controller = Controller(connection: connection, info: device(7, transport: .usb), id: "usb")
        await #expect(throws: TransportError.self) { try await controller.startHaptics() }
        // Rumble falls back to the output report instead.
        try await controller.setRumble(Rumble(left: 50, right: 60))
        let r = try #require(log.last)
        #expect(r[0] == 0x02 && r[1 + OutputLayout.motorLeft] == 50)
        await controller.close()
    }

    @Test func profilesApplyOverUSB() async throws {
        let log = ReportLog()
        let controller = Controller(connection: usbConnection(log), info: device(7, transport: .usb), id: "usb-profile")
        try await controller.apply(ControllerProfile(name: "USB", lightbar: LightbarColor(red: 9, green: 8, blue: 7),
                                                     leftTrigger: TriggerPreset.clickDetent.spec))
        let r = try #require(log.last)
        #expect(r[0] == 0x02)
        #expect(Array(r[(1 + OutputLayout.leftTrigger)..<(1 + OutputLayout.leftTrigger + 11)]) == TriggerPreset.clickDetent.effect.bytes)
        await controller.close()
    }
}
