import Testing
@testable import TactileCore

@Suite struct FeatureReportTests {
    // Source: tools/gen_vectors.py — gyro bias 10/-5/0; plus/minus 1010/-990,
    // 995/-1005, 1000/-1000; speed 540/540; accel ±8192 around bias 100 (x),
    // 0 (y) and 8 (z).
    let cal = hex("05 0a 00 fb ff 00 00 f2 03 22 fc e3 03 13 fc e8 03 18 fc 1c 02 1c 02 64 20 64 e0 00 20 00 e0 08 20 08 e0 00 00 00 00 00 00")

    @Test func calibrationParse() throws {
        let c = try IMUCalibration(featureReport: cal)
        #expect(c.isFromDevice)
        #expect(c.gyro[0] == AxisCalibration(bias: 10, numerator: 1080, denominator: 2000))
        #expect(c.accel[0] == AxisCalibration(bias: 100, numerator: 2, denominator: 16384))
        #expect(c.accel[2] == AxisCalibration(bias: 8, numerator: 2, denominator: 16384))
    }

    @Test func calibrationApply() throws {
        let c = try IMUCalibration(featureReport: cal)
        let out = c.apply(RawIMU(gyro: SIMD3(1010, -5, -1000), accel: SIMD3(8292, 0, -8184), timestamp: 9))
        #expect(abs(out.gyroDegPerSec.x - 540) < 0.001)
        #expect(abs(out.gyroDegPerSec.y) < 0.001)
        #expect(abs(out.gyroDegPerSec.z + 540) < 0.001)
        #expect(abs(out.accelG.x - 1) < 0.0001)
        #expect(abs(out.accelG.z + 1) < 0.0001)
        #expect(out.timestamp == 9)
    }

    @Test func degenerateCalibrationFallsBack() throws {
        let zeros = [UInt8(0x05)] + [UInt8](repeating: 0, count: 40)
        let c = try IMUCalibration(featureReport: zeros)
        #expect(c == .defaults)
        #expect(!c.isFromDevice)
        // Defaults are nominal resolution: 1024 counts per deg/s, 8192 per g.
        let out = c.apply(RawIMU(gyro: SIMD3(1024, 0, 0), accel: SIMD3(8192, 0, 0), timestamp: 0))
        #expect(out.gyroDegPerSec.x == 1 && out.accelG.x == 1)
    }

    // Source: tools/gen_vectors.py, example controller MAC (locally administered)
    // record (02:11:22:33:44:55) stored LSB-first, sealed with feature CRC seed 0xA3.
    @Test func pairingOverBluetooth() throws {
        let raw = hex("09 55 44 33 22 11 02 00 00 00 00 00 00 00 00 00 00 00 00 00 0e c1 38 50")
        let unwrapped = try FeatureReportFraming.unwrap(raw, transport: .bluetooth)
        #expect(unwrapped.count == 20)
        let p = try PairingInfo(featureReport: unwrapped)
        #expect(p.address.description == "02:11:22:33:44:55")
        #expect(p.address == MACAddress(string: "02-11-22-33-44-55"))
    }

    @Test func featureCRCFailure() {
        var raw = hex("09 55 44 33 22 11 02 00 00 00 00 00 00 00 00 00 00 00 00 00 0e c1 38 50")
        raw[3] = 0
        #expect(throws: ParseError.badCRC(reportID: 0x09)) {
            try FeatureReportFraming.unwrap(raw, transport: .bluetooth)
        }
    }

    // Source: tools/gen_vectors.py — hardware 0x414 at offset 24, firmware
    // 0x0110002A at 28, update version 2.36 (0x0224) at 44.
    @Test func firmwareInfo() throws {
        let fw = hex("20 4a 75 6e 20 31 32 20 32 30 32 34 31 30 3a 32 30 3a 33 30 00 00 00 00 14 04 00 00 2a 00 10 01 00 00 00 00 00 00 00 00 00 00 00 00 24 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let f = try FirmwareInfo(featureReport: fw)
        #expect(f.buildDate == "Jun 12 2024")
        #expect(f.buildTime == "10:20:30")
        #expect(f.hardwareVersion == 0x414)
        #expect(f.firmwareVersion == 0x0110_002A)
        #expect(f.updateVersion == 0x0224)
        #expect(f.updateVersionString == "2.36")
    }

    @Test func featureGating() {
        func fw(_ v: UInt16) -> FirmwareInfo {
            FirmwareInfo(buildDate: "", buildTime: "", hardwareVersion: 0, firmwareVersion: 0, updateVersion: v)
        }
        #expect(!FeatureSet.resolve(model: .dualSense, firmware: fw(0x0214)).vibrationV2)
        #expect(FeatureSet.resolve(model: .dualSense, firmware: fw(0x0215)).vibrationV2)
        #expect(!FeatureSet.resolve(model: .dualSense, firmware: nil).vibrationV2)
        #expect(FeatureSet.resolve(model: .dualSenseEdge, firmware: nil).vibrationV2)
        #expect(FeatureSet.resolve(model: .dualSenseEdge, firmware: nil).hasEdgeButtons)
    }

    @Test func normalizeReportID() {
        #expect(FeatureReportFraming.normalize([1, 2, 3], reportID: 0x05, expectedLength: 4) == [5, 1, 2, 3])
        #expect(FeatureReportFraming.normalize([5, 1, 2, 3], reportID: 0x05, expectedLength: 4) == [5, 1, 2, 3])
    }

    @Test func modelIdentification() {
        #expect(ControllerModel(vendorID: 0x054C, productID: 0x0CE6) == .dualSense)
        #expect(ControllerModel(vendorID: 0x054C, productID: 0x0DF2) == .dualSenseEdge)
        #expect(ControllerModel(vendorID: 0x054C, productID: 0x09CC) == nil)
        #expect(ControllerModel(vendorID: 0x045E, productID: 0x0CE6) == nil)
    }
}
