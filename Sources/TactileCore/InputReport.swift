// Input report parsing for report 0x01 (USB full / Bluetooth reduced) and
// Bluetooth report 0x31 (full). Layout facts: PROTOCOL.md §Input.

/// Digital buttons. Bit positions are this library's own and are stable API;
/// they are not the wire layout.
public struct Buttons: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let square = Buttons(rawValue: 1 << 0)
    public static let cross = Buttons(rawValue: 1 << 1)
    public static let circle = Buttons(rawValue: 1 << 2)
    public static let triangle = Buttons(rawValue: 1 << 3)
    public static let l1 = Buttons(rawValue: 1 << 4)
    public static let r1 = Buttons(rawValue: 1 << 5)
    public static let l2 = Buttons(rawValue: 1 << 6)
    public static let r2 = Buttons(rawValue: 1 << 7)
    public static let create = Buttons(rawValue: 1 << 8)
    public static let options = Buttons(rawValue: 1 << 9)
    public static let l3 = Buttons(rawValue: 1 << 10)
    public static let r3 = Buttons(rawValue: 1 << 11)
    public static let ps = Buttons(rawValue: 1 << 12)
    public static let touchpad = Buttons(rawValue: 1 << 13)
    public static let mute = Buttons(rawValue: 1 << 14)
    public static let dpadUp = Buttons(rawValue: 1 << 15)
    public static let dpadRight = Buttons(rawValue: 1 << 16)
    public static let dpadDown = Buttons(rawValue: 1 << 17)
    public static let dpadLeft = Buttons(rawValue: 1 << 18)
    // DualSense Edge only.
    public static let fnLeft = Buttons(rawValue: 1 << 19)
    public static let fnRight = Buttons(rawValue: 1 << 20)
    public static let paddleLeft = Buttons(rawValue: 1 << 21)
    public static let paddleRight = Buttons(rawValue: 1 << 22)

    /// Decodes the wire hat-switch value (0 = N, clockwise to 7 = NW, 8+ = released).
    public static func dpad(hat: UInt8) -> Buttons {
        switch hat & 0x0F {
        case 0: [.dpadUp]
        case 1: [.dpadUp, .dpadRight]
        case 2: [.dpadRight]
        case 3: [.dpadDown, .dpadRight]
        case 4: [.dpadDown]
        case 5: [.dpadDown, .dpadLeft]
        case 6: [.dpadLeft]
        case 7: [.dpadUp, .dpadLeft]
        default: []
        }
    }

    /// Decodes the three wire button bytes shared by every report layout.
    /// `b0`: hat (low nibble) + face buttons; `b1`: shoulders, sticks, create/options;
    /// `b2`: PS, touchpad, mute and (Edge) Fn/paddles in bits 4–7.
    public static func decode(b0: UInt8, b1: UInt8, b2: UInt8, includeEdgeBits: Bool) -> Buttons {
        var b = dpad(hat: b0)
        if b0 & 0x10 != 0 { b.insert(.square) }
        if b0 & 0x20 != 0 { b.insert(.cross) }
        if b0 & 0x40 != 0 { b.insert(.circle) }
        if b0 & 0x80 != 0 { b.insert(.triangle) }
        if b1 & 0x01 != 0 { b.insert(.l1) }
        if b1 & 0x02 != 0 { b.insert(.r1) }
        if b1 & 0x04 != 0 { b.insert(.l2) }
        if b1 & 0x08 != 0 { b.insert(.r2) }
        if b1 & 0x10 != 0 { b.insert(.create) }
        if b1 & 0x20 != 0 { b.insert(.options) }
        if b1 & 0x40 != 0 { b.insert(.l3) }
        if b1 & 0x80 != 0 { b.insert(.r3) }
        if b2 & 0x01 != 0 { b.insert(.ps) }
        if b2 & 0x02 != 0 { b.insert(.touchpad) }
        if b2 & 0x04 != 0 { b.insert(.mute) }
        if includeEdgeBits {
            // UNVERIFIED bit order (PROTOCOL.md §Edge): Fn1, Fn2, left paddle, right paddle.
            if b2 & 0x10 != 0 { b.insert(.fnLeft) }
            if b2 & 0x20 != 0 { b.insert(.fnRight) }
            if b2 & 0x40 != 0 { b.insert(.paddleLeft) }
            if b2 & 0x80 != 0 { b.insert(.paddleRight) }
        }
        return b
    }
}

/// One touchpad contact. Coordinates are raw device units (0...1919, 0...1079).
public struct TouchPoint: Sendable, Hashable, Codable {
    public var active: Bool
    public var id: UInt8
    public var x: UInt16
    public var y: UInt16

    public init(active: Bool, id: UInt8, x: UInt16, y: UInt16) {
        self.active = active
        self.id = id
        self.x = x
        self.y = y
    }

    public static let inactive = TouchPoint(active: false, id: 0, x: 0, y: 0)
    public static let width: UInt16 = 1920
    public static let height: UInt16 = 1080

    /// Decodes the 4-byte wire form: contact byte (bit 7 set = not touching,
    /// low 7 bits = tracking id), then 12-bit X and 12-bit Y packed in 3 bytes.
    public init(wire b: (UInt8, UInt8, UInt8, UInt8)) {
        active = b.0 & 0x80 == 0
        id = b.0 & 0x7F
        x = UInt16(b.1) | UInt16(b.2 & 0x0F) << 8
        y = UInt16(b.2 >> 4) | UInt16(b.3) << 4
    }
}

/// Battery and charging state decoded from the status byte.
public struct BatteryStatus: Sendable, Hashable, Codable {
    public enum Charging: String, Sendable, Codable {
        case discharging, charging, full, error, unknown
    }

    /// 0...100, in steps of 10 (the device reports tenths; values above 10 clamp).
    /// 0 when `charging` is `.error` or `.unknown`.
    public var percent: Int
    public var charging: Charging

    public init(percent: Int, charging: Charging) {
        self.percent = percent
        self.charging = charging
    }

    public init(statusByte s: UInt8) {
        let level = Int(s & 0x0F)
        switch s >> 4 {
        case 0x0: charging = .discharging
        case 0x1: charging = .charging
        case 0x2: charging = .full
        case 0xA, 0xB, 0xF: charging = .error
        default: charging = .unknown
        }
        // Sony reports 0-10 (tenths). When full, the level nibble is not meaningful;
        // in error/unknown states it is not a charge level, so report 0 (as LNX does).
        switch charging {
        case .full: percent = 100
        case .discharging, .charging: percent = min(level * 10 + 5, 100)
        case .error, .unknown: percent = 0
        }
    }
}

/// Raw, uncalibrated IMU sample.
public struct RawIMU: Sendable, Hashable, Codable {
    public var gyro: SIMD3<Int16>
    public var accel: SIMD3<Int16>
    /// Sensor timestamp in device ticks (0.33 µs per tick per SDL; UNVERIFIED on BT).
    public var timestamp: UInt32

    public init(gyro: SIMD3<Int16>, accel: SIMD3<Int16>, timestamp: UInt32) {
        self.gyro = gyro
        self.accel = accel
        self.timestamp = timestamp
    }
}

/// Which wire layout produced an `InputState`.
public enum InputReportKind: String, Sendable, Codable {
    /// Bluetooth report 0x01: sticks, triggers, buttons only. No IMU, touch or battery.
    case bluetoothReduced
    /// Bluetooth report 0x31 (full, CRC-protected).
    case bluetoothFull
    /// USB report 0x01 (full).
    case usbFull
}

/// A decoded controller input snapshot.
public struct InputState: Sendable, Hashable, Codable {
    public var kind: InputReportKind
    public var leftStick: SIMD2<UInt8>
    public var rightStick: SIMD2<UInt8>
    public var l2: UInt8
    public var r2: UInt8
    public var buttons: Buttons
    /// Device sequence counter (0-255), when present in the layout.
    public var sequence: UInt8?
    public var imu: RawIMU?
    public var touch: (TouchPoint, TouchPoint)? {
        get { touchPoints.count == 2 ? (touchPoints[0], touchPoints[1]) : nil }
        set { touchPoints = newValue.map { [$0.0, $0.1] } ?? [] }
    }
    public var touchPoints: [TouchPoint]
    public var battery: BatteryStatus?
    /// Headphone jack state, when reported (UNVERIFIED bit positions).
    public var headphonesConnected: Bool?
    public var micConnected: Bool?

    public init(kind: InputReportKind) {
        self.kind = kind
        leftStick = SIMD2(128, 128)
        rightStick = SIMD2(128, 128)
        l2 = 0
        r2 = 0
        buttons = []
        sequence = nil
        imu = nil
        touchPoints = []
        battery = nil
        headphonesConnected = nil
        micConnected = nil
    }

    public static func == (a: InputState, b: InputState) -> Bool {
        a.kind == b.kind && a.leftStick == b.leftStick && a.rightStick == b.rightStick
            && a.l2 == b.l2 && a.r2 == b.r2 && a.buttons == b.buttons && a.sequence == b.sequence
            && a.imu == b.imu && a.touchPoints == b.touchPoints && a.battery == b.battery
            && a.headphonesConnected == b.headphonesConnected && a.micConnected == b.micConnected
    }

    public func hash(into h: inout Hasher) {
        h.combine(kind); h.combine(buttons); h.combine(sequence); h.combine(l2); h.combine(r2)
    }

    enum CodingKeys: String, CodingKey {
        case kind, leftStick, rightStick, l2, r2, buttons, sequence, imu, touchPoints, battery
        case headphonesConnected, micConnected
    }
}

/// Errors from report parsing.
public enum ParseError: Error, Sendable, Equatable {
    case empty
    case unknownReportID(UInt8)
    case tooShort(reportID: UInt8, expected: Int, actual: Int)
    case badCRC(reportID: UInt8)
}

/// Parses DualSense input reports.
public enum InputParser {
    public static let usbFullLength = 64
    public static let bluetoothReducedLength = 10
    public static let bluetoothFullLength = 78

    /// Parses one input report. `bytes[0]` must be the report ID.
    ///
    /// - Parameters:
    ///   - transport: needed because report 0x01 means different things on USB and Bluetooth.
    ///   - model: enables Edge-only button bits.
    ///   - verifyCRC: check the trailing CRC of Bluetooth 0x31 (seed 0xA1).
    public static func parse(
        _ bytes: [UInt8], transport: Transport, model: ControllerModel, verifyCRC: Bool = true
    ) throws(ParseError) -> InputState {
        guard let id = bytes.first else { throw .empty }
        let edge = model == .dualSenseEdge
        switch (id, transport) {
        case (0x01, .bluetooth):
            return try parseBluetoothReduced(bytes, edge: edge)
        case (0x01, .usb):
            guard bytes.count >= usbFullLength else {
                throw .tooShort(reportID: id, expected: usbFullLength, actual: bytes.count)
            }
            return parseCommon(bytes, base: 1, kind: .usbFull, edge: edge)
        case (0x31, _):
            guard bytes.count >= bluetoothFullLength else {
                throw .tooShort(reportID: id, expected: bluetoothFullLength, actual: bytes.count)
            }
            if verifyCRC, !CRC32.verify(bytes[0..<bluetoothFullLength], prefix: .input) {
                throw .badCRC(reportID: id)
            }
            // bytes[1] is a sequence/tag byte; the common block starts at offset 2.
            return parseCommon(bytes, base: 2, kind: .bluetoothFull, edge: edge)
        default:
            throw .unknownReportID(id)
        }
    }

    static func parseBluetoothReduced(_ bytes: [UInt8], edge: Bool) throws(ParseError) -> InputState {
        guard bytes.count >= bluetoothReducedLength else {
            throw .tooShort(reportID: 0x01, expected: bluetoothReducedLength, actual: bytes.count)
        }
        var s = InputState(kind: .bluetoothReduced)
        s.leftStick = SIMD2(bytes[1], bytes[2])
        s.rightStick = SIMD2(bytes[3], bytes[4])
        // bytes[7] top 6 bits are a counter in this layout, so no mute/Edge bits.
        s.buttons = Buttons.decode(b0: bytes[5], b1: bytes[6], b2: bytes[7] & 0x03, includeEdgeBits: false)
        s.l2 = bytes[8]
        s.r2 = bytes[9]
        return s
    }

    /// Offsets of the 63-byte common block (relative to `base`).
    enum Common {
        static let lx = 0, ly = 1, rx = 2, ry = 3, l2 = 4, r2 = 5
        static let sequence = 6
        static let buttons0 = 7, buttons1 = 8, buttons2 = 9
        static let gyro = 15, accel = 21, sensorTimestamp = 27
        static let touch0 = 32, touch1 = 36
        static let status0 = 52, status1 = 53
        static let length = 63
    }

    static func parseCommon(_ bytes: [UInt8], base: Int, kind: InputReportKind, edge: Bool) -> InputState {
        let r = ByteReader(bytes, base: base)
        var s = InputState(kind: kind)
        s.leftStick = SIMD2(r.u8(Common.lx) ?? 128, r.u8(Common.ly) ?? 128)
        s.rightStick = SIMD2(r.u8(Common.rx) ?? 128, r.u8(Common.ry) ?? 128)
        s.l2 = r.u8(Common.l2) ?? 0
        s.r2 = r.u8(Common.r2) ?? 0
        s.sequence = r.u8(Common.sequence)
        s.buttons = Buttons.decode(
            b0: r.u8(Common.buttons0) ?? 0x08, b1: r.u8(Common.buttons1) ?? 0,
            b2: r.u8(Common.buttons2) ?? 0, includeEdgeBits: edge)
        if let gx = r.i16(Common.gyro), let gy = r.i16(Common.gyro + 2), let gz = r.i16(Common.gyro + 4),
           let ax = r.i16(Common.accel), let ay = r.i16(Common.accel + 2), let az = r.i16(Common.accel + 4),
           let ts = r.u32(Common.sensorTimestamp) {
            s.imu = RawIMU(gyro: SIMD3(gx, gy, gz), accel: SIMD3(ax, ay, az), timestamp: ts)
        }
        var points: [TouchPoint] = []
        for off in [Common.touch0, Common.touch1] {
            if let a = r.u8(off), let b = r.u8(off + 1), let c = r.u8(off + 2), let d = r.u8(off + 3) {
                points.append(TouchPoint(wire: (a, b, c, d)))
            }
        }
        s.touchPoints = points
        if let st = r.u8(Common.status0) { s.battery = BatteryStatus(statusByte: st) }
        if let st1 = r.u8(Common.status1) {
            s.headphonesConnected = st1 & 0x01 != 0
            s.micConnected = st1 & 0x02 != 0
        }
        return s
    }
}
