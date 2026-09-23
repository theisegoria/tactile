// EXPERIMENTAL (gate 6): speaker / headphone audio over Bluetooth.
//
// Research lead (🔬, unlicensed repository, facts only): output report 0x36
// carries Opus audio in CELT mode, 48 kHz stereo, one 10 ms frame per report.
// Nothing about the framing is confirmed, so every detail is a field of
// `SpeakerAudioFraming`. The report length should come from the controller's
// own report descriptor (`HIDDescriptor`), not from a guess.

public struct SpeakerAudioFraming: Sendable, Hashable, Codable {
    public enum LengthPrefix: String, Sendable, Hashable, Codable {
        case none, u8, u16LittleEndian
    }

    public var reportID: UInt8 = 0x36
    /// Total report length including report ID and CRC. Take it from the
    /// descriptor: `descriptor.report(.output, id: 0x36)?.byteLength` (+4 for the
    /// CRC over Bluetooth if the descriptor does not already include it).
    public var reportLength: Int
    /// Byte 1 = 4-bit sequence + 4-bit tag, like 0x31/0x32. 🔬
    public var tag: UInt8 = 0
    public var sequenceInHighNibble = true
    /// Offset where the optional length prefix (then the Opus packet) starts. 🔬
    public var payloadOffset = 2
    public var lengthPrefix: LengthPrefix = .u8
    /// Append a CRC-32 seeded with 0xA2 in the last four bytes.
    public var crc = true

    public init(reportLength: Int) {
        self.reportLength = reportLength
    }

    /// Largest Opus packet that fits.
    public var maxPacketBytes: Int {
        let prefix = lengthPrefix == .none ? 0 : lengthPrefix == .u8 ? 1 : 2
        let cap = reportLength - payloadOffset - prefix - (crc ? 4 : 0)
        return lengthPrefix == .u8 ? min(cap, 255) : max(cap, 0)
    }
}

/// Builds speaker-audio reports from already-encoded Opus packets.
public struct SpeakerAudioReportBuilder: Sendable {
    public enum BuildError: Error, Sendable, Equatable {
        case packetTooLarge(size: Int, max: Int)
        case badFraming(String)
    }

    public var framing: SpeakerAudioFraming
    public private(set) var sequence: UInt8 = 0

    public init(framing: SpeakerAudioFraming) {
        self.framing = framing
    }

    public mutating func build(opusPacket p: [UInt8]) throws(BuildError) -> [UInt8] {
        let f = framing
        guard f.reportLength >= f.payloadOffset + (f.crc ? 5 : 1), f.payloadOffset >= 1 else {
            throw .badFraming("reportLength \(f.reportLength) too small for payloadOffset \(f.payloadOffset)")
        }
        guard p.count <= f.maxPacketBytes else { throw .packetTooLarge(size: p.count, max: f.maxPacketBytes) }
        var r = [UInt8](repeating: 0, count: f.reportLength)
        r[0] = f.reportID
        if f.payloadOffset >= 2 {
            let seq = sequence & 0x0F, tag = f.tag & 0x0F
            r[1] = f.sequenceInHighNibble ? (seq << 4 | tag) : (tag << 4 | seq)
        }
        var i = f.payloadOffset
        switch f.lengthPrefix {
        case .none: break
        case .u8:
            r[i] = UInt8(p.count); i += 1
        case .u16LittleEndian:
            r[i] = UInt8(truncatingIfNeeded: p.count); r[i + 1] = UInt8(truncatingIfNeeded: p.count >> 8); i += 2
        }
        r.replaceSubrange(i..<(i + p.count), with: p)
        if f.crc { CRC32.seal(&r, prefix: .output) }
        sequence = (sequence + 1) & 0x0F
        return r
    }
}
