// Minimal HID report-descriptor parser (USB HID 1.11 §6.2.2): computes the
// size of every input, output and feature report. Used for gate-6 research
// (sizes of report 0x36, uplink reports, Edge feature reports) and to cope with
// the Edge's differing Bluetooth descriptor. Never used to identify the model.

public enum HIDReportKind: String, Sendable, Codable, CaseIterable {
    case input, output, feature
}

/// One declared report.
public struct HIDReportInfo: Sendable, Hashable, Codable, CustomStringConvertible {
    public var kind: HIDReportKind
    /// 0 when the descriptor declares no report IDs.
    public var reportID: UInt8
    /// Payload bits, excluding the report-ID byte.
    public var bitLength: Int
    /// First usage page seen for this report (vendor pages are 0xFF00–0xFFFF).
    public var usagePage: UInt16?

    /// Bytes on the wire including the report-ID byte (when IDs are used).
    public var byteLength: Int { (bitLength + 7) / 8 + (reportID == 0 ? 0 : 1) }
    public var isVendorDefined: Bool { (usagePage ?? 0) >= 0xFF00 }

    public var description: String {
        "\(kind.rawValue) 0x\(hexString(reportID, width: 2)): \(byteLength) bytes"
            + (usagePage.map { " (usage page 0x\(hexString($0, width: 4)))" } ?? "")
    }
}

public struct HIDDescriptor: Sendable, Hashable, Codable {
    public enum ParseError: Error, Sendable, Equatable {
        case truncated(offset: Int)
        case popWithoutPush(offset: Int)
    }

    public var reports: [HIDReportInfo]

    public func report(_ kind: HIDReportKind, id: UInt8) -> HIDReportInfo? {
        reports.first { $0.kind == kind && $0.reportID == id }
    }

    public func reports(_ kind: HIDReportKind) -> [HIDReportInfo] {
        reports.filter { $0.kind == kind }.sorted { $0.reportID < $1.reportID }
    }

    private struct Globals {
        var usagePage: UInt16 = 0
        var reportSize = 0
        var reportCount = 0
        var reportID: UInt8 = 0
    }

    public init(parsing d: [UInt8]) throws(ParseError) {
        var g = Globals()
        var stack: [Globals] = []
        var bits: [String: (HIDReportInfo)] = [:]
        var order: [String] = []
        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {  // long item: FE, size, tag, data
                guard i + 1 < d.count else { throw .truncated(offset: i) }
                let n = Int(d[i + 1])
                guard i + 3 + n <= d.count else { throw .truncated(offset: i) }
                i += 3 + n
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            guard i + size < d.count else { throw .truncated(offset: i) }
            var value: UInt32 = 0
            for k in 0..<size { value |= UInt32(d[i + 1 + k]) << (8 * k) }
            let tag = prefix & 0xFC
            switch tag {
            case 0x04: g.usagePage = UInt16(truncatingIfNeeded: value)
            case 0x74: g.reportSize = Int(value)
            case 0x94: g.reportCount = Int(value)
            case 0x84: g.reportID = UInt8(truncatingIfNeeded: value)
            case 0xA4: stack.append(g)
            case 0xB4:
                guard let top = stack.popLast() else { throw .popWithoutPush(offset: i) }
                g = top
            case 0x80, 0x90, 0xB0:
                let kind: HIDReportKind = tag == 0x80 ? .input : tag == 0x90 ? .output : .feature
                let key = "\(kind.rawValue)-\(g.reportID)"
                let add = max(0, g.reportSize) * max(0, g.reportCount)
                if var r = bits[key] {
                    r.bitLength += add
                    bits[key] = r
                } else {
                    bits[key] = HIDReportInfo(kind: kind, reportID: g.reportID, bitLength: add, usagePage: g.usagePage)
                    order.append(key)
                }
            default: break
            }
            i += 1 + size
        }
        reports = order.compactMap { bits[$0] }
    }
}

/// Uppercase, zero-padded hex without Foundation.
func hexString<T: BinaryInteger>(_ v: T, width: Int) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}
