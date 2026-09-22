import Testing
@testable import TactileCore

/// Regression: DeviceConnection passes the protocol feature lengths (which on
/// Bluetooth already include the trailing CRC) straight to `normalize`.
/// A stripped-ID reply whose first payload byte equals the report ID must still
/// get the ID prepended, so the CRC verifies and fields are not shifted.
@Suite struct FeatureLengthFramingTests {
    @Test func strippedBluetoothCalibrationWithIDLikeFirstByte() throws {
        var report = [UInt8](repeating: 0, count: IMUCalibration.featureReportLength - 4)
        report[0] = IMUCalibration.featureReportID
        report[1] = 0x05  // gyro pitch bias low byte equal to the report ID
        report[2] = 0x00
        report += [0, 0, 0, 0]
        CRC32.seal(&report, prefix: .feature)
        #expect(report.count == IMUCalibration.featureReportLength)

        let stripped = Array(report.dropFirst())
        let normalized = FeatureReportFraming.normalize(
            stripped, reportID: IMUCalibration.featureReportID,
            expectedLength: IMUCalibration.featureReportLength)
        #expect(normalized == report)
        let unwrapped = try FeatureReportFraming.unwrap(normalized, transport: .bluetooth)
        #expect(unwrapped.count == IMUCalibration.featureReportLength - 4)
        #expect(unwrapped[1] == 0x05)
    }

    @Test func strippedBluetoothPairingWithIDLikeFirstByte() {
        var report = [UInt8](repeating: 0, count: PairingInfo.length)
        report[0] = PairingInfo.featureReportID
        report[1] = 0x09  // MAC least-significant byte equal to the report ID
        CRC32.seal(&report, prefix: .feature)
        let normalized = FeatureReportFraming.normalize(
            Array(report.dropFirst()), reportID: PairingInfo.featureReportID, expectedLength: PairingInfo.length)
        #expect(normalized == report)
        #expect(CRC32.verify(normalized, prefix: .feature))
    }
}
