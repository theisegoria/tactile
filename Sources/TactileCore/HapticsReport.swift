// Bluetooth audio-haptics output report 0x32.
//
// CLEAN-ROOM implementation from the facts documented in PROTOCOL.md §Haptics
// (originally reverse engineered by the SAxense project, MPL-2.0). No SAxense
// code was read into or adapted for this file. Every framing detail that is not
// confirmed on hardware is a field of `HapticsFraming` so it can be corrected
// without an API change.

/// Framing parameters for report 0x32. Defaults are the documented values;
/// all are UNVERIFIED until confirmed on hardware (see TESTING.md).
public struct HapticsFraming: Sendable, Hashable, Codable {
    /// Total report length including report ID and CRC.
    public var reportLength: Int = 141
    /// 4-bit tag placed in byte 1 alongside the sequence number.
    public var tag: UInt8 = 0x0
    /// When true the sequence number occupies the high nibble of byte 1 and the
    /// tag the low nibble (matching report 0x31's convention); otherwise swapped.
    public var sequenceInHighNibble: Bool = true
    /// Sub-packet header byte for the control sub-packet (id 0x11, "sized" bit 7).
    public var controlHeader: UInt8 = 0x91
    /// Payload of the 7-byte control sub-packet, excluding the trailing counter.
    public var controlPayload: [UInt8] = [0xFE, 0x00, 0x00, 0x00, 0x00, 0xFF]
    /// Sub-packet header byte for the sample sub-packet (id 0x12, "sized" bit 7).
    public var samplesHeader: UInt8 = 0x92
    /// Samples are signed two's-complement when true, offset-binary when false.
    public var signedSamples: Bool = true

    public init() {}

    public static let documented = HapticsFraming()
}

/// Audio format constants for Bluetooth haptics.
public enum HapticsFormat {
    public static let sampleRate: Double = 3000
    public static let channels = 2
    public static let framesPerReport = 32
    public static let bytesPerReport = framesPerReport * channels  // 64
    /// Report period: 32 frames / 3000 Hz = 10.666… ms.
    public static let reportPeriodSeconds: Double = Double(framesPerReport) / sampleRate
    public static let reportID: UInt8 = 0x32
}

/// Builds report 0x32. Keeps the 4-bit report sequence and the 8-bit running
/// counter carried in the control sub-packet.
public struct HapticsReportBuilder: Sendable {
    public var framing: HapticsFraming
    public private(set) var sequence: UInt8 = 0
    public private(set) var counter: UInt8 = 0

    public init(framing: HapticsFraming = .documented) {
        self.framing = framing
    }

    /// Builds one report from 32 interleaved stereo frames of signed 8-bit samples
    /// (L, R, L, R…). Missing samples are padded with silence; extra are ignored.
    public mutating func build(samples: [Int8]) -> [UInt8] {
        let f = framing
        var r = [UInt8](repeating: 0, count: max(f.reportLength, 8))
        r[0] = HapticsFormat.reportID
        let seq = sequence & 0x0F, tag = f.tag & 0x0F
        r[1] = f.sequenceInHighNibble ? (seq << 4 | tag) : (tag << 4 | seq)
        var i = 2
        func put(_ b: UInt8) {
            if i < r.count - 4 { r[i] = b }
            i += 1
        }
        // Control sub-packet: header, length 7, payload(6) + counter.
        let control = Array(f.controlPayload.prefix(6)) + Array(repeating: 0, count: max(0, 6 - f.controlPayload.count))
        put(f.controlHeader); put(7)
        control.forEach(put)
        put(counter)
        // Sample sub-packet: header, length 64, samples.
        put(f.samplesHeader); put(UInt8(HapticsFormat.bytesPerReport))
        for k in 0..<HapticsFormat.bytesPerReport {
            let s: Int8 = k < samples.count ? samples[k] : 0
            put(f.signedSamples ? UInt8(bitPattern: s) : UInt8(bitPattern: s) ^ 0x80)
        }
        CRC32.seal(&r, prefix: .output)
        sequence = (sequence + 1) & 0x0F
        counter &+= 1
        return r
    }
}
