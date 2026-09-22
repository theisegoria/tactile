// Feature report decoders: 0x09 pairing info, 0x20 firmware info.

/// A Bluetooth MAC address, printed most-significant byte first.
public struct MACAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    public var bytes: [UInt8]  // 6 bytes, most significant first

    public init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// Parses "02:11:22:33:44:55" or "02-11-22-33-44-55".
    public init?(string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard let b = UInt8(p, radix: 16) else { return nil }
            out.append(b)
        }
        bytes = out
    }

    public var description: String {
        bytes.map { b in
            let s = String(b, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: ":")
    }
}

/// Feature report 0x09: pairing info. Bytes 1...6 hold the controller's own
/// Bluetooth address, least-significant byte first.
public struct PairingInfo: Sendable, Hashable, Codable {
    public static let featureReportID: UInt8 = 0x09
    public static let length = 20

    public var address: MACAddress

    public init(featureReport bytes: [UInt8]) throws(ParseError) {
        guard let id = bytes.first else { throw .empty }
        guard id == Self.featureReportID else { throw .unknownReportID(id) }
        guard bytes.count >= 7 else { throw .tooShort(reportID: id, expected: 7, actual: bytes.count) }
        guard let mac = MACAddress(bytes: Array(bytes[1...6].reversed())) else {
            throw .tooShort(reportID: id, expected: 7, actual: bytes.count)
        }
        address = mac
    }
}

/// Feature report 0x20: firmware information (64 bytes).
public struct FirmwareInfo: Sendable, Hashable, Codable {
    public static let featureReportID: UInt8 = 0x20
    public static let length = 64

    /// Build date and time strings (ASCII, bytes 1–11 and 12–19).
    public var buildDate: String
    public var buildTime: String
    /// Little-endian u32 at offset 24.
    public var hardwareVersion: UInt32
    /// Little-endian u32 at offset 28.
    public var firmwareVersion: UInt32
    /// Little-endian u16 at offset 44, encoded major << 8 | minor. This is the
    /// "update version" the Linux driver compares against 2.21 for vibration v2.
    public var updateVersion: UInt16

    public init(buildDate: String, buildTime: String, hardwareVersion: UInt32, firmwareVersion: UInt32, updateVersion: UInt16) {
        self.buildDate = buildDate
        self.buildTime = buildTime
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
        self.updateVersion = updateVersion
    }

    public init(featureReport bytes: [UInt8]) throws(ParseError) {
        guard let id = bytes.first else { throw .empty }
        guard id == Self.featureReportID else { throw .unknownReportID(id) }
        guard bytes.count >= 46 else { throw .tooShort(reportID: id, expected: 46, actual: bytes.count) }
        let r = ByteReader(bytes)
        func ascii(_ range: Range<Int>) -> String {
            String(decoding: bytes[range].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        }
        buildDate = ascii(1..<12)
        buildTime = ascii(12..<20)
        hardwareVersion = r.u32(24) ?? 0
        firmwareVersion = r.u32(28) ?? 0
        updateVersion = r.u16(44) ?? 0
    }

    public var updateVersionString: String {
        let minor = updateVersion & 0xFF
        return "\(updateVersion >> 8).\(minor < 10 ? "0" : "")\(minor)"
    }
}

/// Features that depend on model and firmware.
public struct FeatureSet: Sendable, Hashable, Codable {
    /// Use the "vibration v2" rumble path (valid_flag2 bit 2) instead of the legacy
    /// compatible-vibration flag.
    public var vibrationV2: Bool
    public var hasEdgeButtons: Bool

    public init(vibrationV2: Bool, hasEdgeButtons: Bool) {
        self.vibrationV2 = vibrationV2
        self.hasEdgeButtons = hasEdgeButtons
    }

    /// DualSense firmware update version from which vibration v2 is available.
    public static let vibrationV2MinimumUpdateVersion: UInt16 = 0x0215  // 2.21

    public static func resolve(model: ControllerModel, firmware: FirmwareInfo?) -> FeatureSet {
        switch model {
        case .dualSenseEdge:
            return FeatureSet(vibrationV2: true, hasEdgeButtons: true)
        case .dualSense:
            let v2 = (firmware?.updateVersion ?? 0) >= vibrationV2MinimumUpdateVersion
            return FeatureSet(vibrationV2: v2, hasEdgeButtons: false)
        }
    }
}
