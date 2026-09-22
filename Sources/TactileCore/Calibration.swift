// IMU calibration from feature report 0x05. Maths follows the documented
// DualSense calibration layout (PROTOCOL.md §Calibration). Written from the
// documented facts; no GPL code was copied.

/// Per-axis linear calibration: `(raw - bias) * numerator / denominator`.
public struct AxisCalibration: Sendable, Hashable, Codable {
    public var bias: Int32
    public var numerator: Int32
    public var denominator: Int32

    public init(bias: Int32, numerator: Int32, denominator: Int32) {
        self.bias = bias
        self.numerator = numerator
        self.denominator = denominator
    }

    @inlinable public func apply(_ raw: Int16) -> Float {
        guard denominator != 0 else { return Float(raw) }
        return Float(Int32(raw) - bias) * Float(numerator) / Float(denominator)
    }
}

/// Calibration for all six IMU axes. Output units: degrees/second and g.
public struct IMUCalibration: Sendable, Hashable, Codable {
    /// Raw gyro counts per degree/second after calibration scaling.
    public static let gyroResolutionPerDegPerSec: Int32 = 1024
    /// Raw accelerometer counts per g.
    public static let accelResolutionPerG: Int32 = 8192
    public static let featureReportID: UInt8 = 0x05
    /// Length of report 0x05 including the ID byte (USB). Bluetooth appends a CRC.
    public static let featureReportLength = 41

    public var gyro: [AxisCalibration]  // pitch (x), yaw (y), roll (z)
    public var accel: [AxisCalibration]  // x, y, z
    /// False when the report contained degenerate values and defaults were used.
    public var isFromDevice: Bool

    /// Nominal calibration used when report 0x05 is unavailable or degenerate.
    public static let defaults = IMUCalibration(
        gyro: Array(repeating: AxisCalibration(bias: 0, numerator: 1, denominator: gyroResolutionPerDegPerSec), count: 3),
        accel: Array(repeating: AxisCalibration(bias: 0, numerator: 1, denominator: accelResolutionPerG), count: 3),
        isFromDevice: false)

    public init(gyro: [AxisCalibration], accel: [AxisCalibration], isFromDevice: Bool) {
        self.gyro = gyro
        self.accel = accel
        self.isFromDevice = isFromDevice
    }

    /// Parses feature report 0x05. `bytes[0]` must be 0x05.
    ///
    /// Layout (little-endian int16 after the ID byte):
    /// gyro bias p/y/r; gyro plus/minus pairs for p, y, r; gyro speed plus, minus;
    /// accel plus/minus pairs for x, y, z.
    public init(featureReport bytes: [UInt8]) throws(ParseError) {
        guard let id = bytes.first else { throw .empty }
        guard id == Self.featureReportID else { throw .unknownReportID(id) }
        guard bytes.count >= 35 else {
            throw .tooShort(reportID: id, expected: 35, actual: bytes.count)
        }
        let r = ByteReader(bytes)
        func v(_ o: Int) -> Int32 { Int32(r.i16(o) ?? 0) }
        let bias = [v(1), v(3), v(5)]
        let plus = [v(7), v(11), v(15)]
        let minus = [v(9), v(13), v(17)]
        let speed2x = v(19) + v(21)

        var gyro: [AxisCalibration] = []
        var degenerate = false
        for i in 0..<3 {
            let denom = abs(plus[i] - bias[i]) + abs(minus[i] - bias[i])
            if denom == 0 || speed2x == 0 { degenerate = true }
            // speed2x * RES / denom maps raw->counts; dividing by RES gives deg/s,
            // so the net factor is speed2x / denom.
            gyro.append(AxisCalibration(bias: bias[i], numerator: speed2x, denominator: denom))
        }

        var accel: [AxisCalibration] = []
        for i in 0..<3 {
            let p = v(23 + i * 4), m = v(25 + i * 4)
            let range2g = p - m
            if range2g == 0 { degenerate = true }
            accel.append(AxisCalibration(bias: p - range2g / 2, numerator: 2, denominator: range2g))
        }

        if degenerate {
            self = .defaults
        } else {
            self.init(gyro: gyro, accel: accel, isFromDevice: true)
        }
    }

    public func apply(_ raw: RawIMU) -> CalibratedIMU {
        CalibratedIMU(
            gyroDegPerSec: SIMD3(gyro[0].apply(raw.gyro.x), gyro[1].apply(raw.gyro.y), gyro[2].apply(raw.gyro.z)),
            accelG: SIMD3(accel[0].apply(raw.accel.x), accel[1].apply(raw.accel.y), accel[2].apply(raw.accel.z)),
            timestamp: raw.timestamp)
    }
}

public struct CalibratedIMU: Sendable, Hashable, Codable {
    public var gyroDegPerSec: SIMD3<Float>
    public var accelG: SIMD3<Float>
    public var timestamp: UInt32

    public init(gyroDegPerSec: SIMD3<Float>, accelG: SIMD3<Float>, timestamp: UInt32) {
        self.gyroDegPerSec = gyroDegPerSec
        self.accelG = accelG
        self.timestamp = timestamp
    }
}
