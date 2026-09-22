// CRC-32 as used by DualSense Bluetooth reports.
//
// Reflected polynomial 0xEDB88320, initial value 0xFFFFFFFF, final XOR 0xFFFFFFFF
// (the zlib/IEEE CRC). Bluetooth reports are checksummed over a one-byte HID
// transaction prefix followed by the report bytes. See PROTOCOL.md §CRC.

/// Streaming CRC-32 (IEEE, reflected, zlib-compatible).
public struct CRC32: Sendable, Equatable {
    /// The HID-over-Bluetooth transaction header bytes that seed DualSense CRCs.
    public enum Prefix: UInt8, Sendable {
        /// DATA | Input. Seeds input report CRCs.
        case input = 0xA1
        /// DATA | Output. Seeds output report CRCs (0x31, 0x32).
        case output = 0xA2
        /// DATA | Feature. Seeds feature report CRCs returned over Bluetooth.
        case feature = 0xA3
    }

    static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public init(prefix: Prefix) {
        update(prefix.rawValue)
    }

    public mutating func update(_ byte: UInt8) {
        state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
    }

    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { update(b) }
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    /// One-shot checksum of `bytes`.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c = CRC32()
        c.update(bytes)
        return c.value
    }

    /// One-shot checksum of `prefix` followed by `bytes`.
    public static func checksum<S: Sequence>(prefix: Prefix, _ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c = CRC32(prefix: prefix)
        c.update(bytes)
        return c.value
    }

    /// Writes the CRC of `prefix + report[0..<report.count-4]` into the last four
    /// bytes of `report`, little-endian.
    public static func seal(_ report: inout [UInt8], prefix: Prefix) {
        precondition(report.count > 4, "report too short to carry a CRC")
        let n = report.count - 4
        let crc = checksum(prefix: prefix, report[0..<n])
        report[n] = UInt8(truncatingIfNeeded: crc)
        report[n + 1] = UInt8(truncatingIfNeeded: crc >> 8)
        report[n + 2] = UInt8(truncatingIfNeeded: crc >> 16)
        report[n + 3] = UInt8(truncatingIfNeeded: crc >> 24)
    }

    /// Returns true when the trailing four bytes of `report` are a valid CRC.
    public static func verify<C: Collection>(_ report: C, prefix: Prefix) -> Bool
    where C.Element == UInt8, C.Index == Int {
        guard report.count > 4 else { return false }
        let start = report.startIndex
        let n = report.count - 4
        let expected = checksum(prefix: prefix, report[start..<(start + n)])
        let stored = UInt32(report[start + n])
            | UInt32(report[start + n + 1]) << 8
            | UInt32(report[start + n + 2]) << 16
            | UInt32(report[start + n + 3]) << 24
        return expected == stored
    }
}
