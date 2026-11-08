// EXPERIMENTAL (gate 6): speaker / headphone audio over Bluetooth, report 0x36.
//
// Layout from public MIT-licensed implementations (facts only, no code):
// daidr/dualsense-tester, matt400/dualsense-bridge and awalol/DS5Dongle (as
// cited by others). See PROTOCOL.md §Speaker. Unverified on hardware.
//
//   [0]  0x36
//   [1]  sequence << 4 (4-bit, +1 per report)
//   [2]  0x91, 7: 0xFE, five buffer bytes, running counter     (control)
//   [11] 0x92, 64: 32 stereo frames of signed 8-bit haptics at 3 kHz
//   [77] 0x93 (speaker) or 0x96 (headphones), length, Opus frame
//   zero padding, CRC-32 (seed 0xA2) in the last four bytes; 398 bytes total
//
// One report every 512/48000 s (10.667 ms): the same cadence as report 0x32,
// so haptics and audio travel together. Each Opus frame encodes 480 samples
// as 48 kHz, so the audio itself must be at 45 kHz (480 per 10.667 ms).
//
// The earlier guessed layout (sequence byte, length prefix, Opus) is kept as
// `Layout.lengthPrefixed` for research tools; it has no public source.

public struct SpeakerAudioFraming: Sendable, Hashable, Codable {
    public enum Layout: String, Sendable, Hashable, Codable {
        /// Control, haptics and audio sub-packets (public implementations).
        case subPackets
        /// The pre-0.3 guess: sequence byte, length prefix, Opus packet.
        case lengthPrefixed
    }
    public enum LengthPrefix: String, Sendable, Hashable, Codable {
        case none, u8, u16LittleEndian
    }
    /// Audio sub-packet header: where the controller plays the frame.
    public enum Destination: UInt8, Sendable, Hashable, Codable, CaseIterable {
        case speaker = 0x93
        case headphones = 0x96
    }

    /// Total report length in the public implementations.
    public static let documentedLength = 398
    /// One report per 32 haptic frames at 3 kHz = 512 samples at 48 kHz.
    public static let packetPeriodSeconds = 512.0 / 48_000
    /// PCM rate the Opus frames carry in real time: 480 samples per period.
    public static let inputSampleRate = 45_000.0
    /// Opus frames are CBR 160 kb/s stereo CELT: 200 bytes per 10 ms frame.
    public static let opusBitRate = 160_000
    public static let opusFrameBytes = 200

    public var layout: Layout = .subPackets
    public var reportID: UInt8 = 0x36
    /// Total report length including report ID and CRC. Prefer the
    /// controller's descriptor (`Controller.speakerFraming()`).
    public var reportLength: Int
    /// Byte 1 = 4-bit sequence + 4-bit tag.
    public var tag: UInt8 = 0
    public var sequenceInHighNibble = true
    /// Append a CRC-32 seeded with 0xA2 in the last four bytes (Bluetooth).
    public var crc = true

    // Sub-packet layout.
    public var destination: Destination = .speaker
    public var controlHeader: UInt8 = 0x91
    /// 0xFE (bit 0 clear keeps the microphone uplink off), then five buffer
    /// bytes; DS5Dongle uses 48 during speaker playback, 16 is the minimum.
    public var controlPayload: [UInt8] = [0xFE, 0x30, 0x30, 0x30, 0x30, 0x30]
    public var hapticsHeader: UInt8 = 0x92
    public var signedHapticSamples = true

    // Length-prefixed (research) layout.
    public var payloadOffset = 2
    public var lengthPrefix: LengthPrefix = .u8

    public init(reportLength: Int = SpeakerAudioFraming.documentedLength) {
        self.reportLength = reportLength
    }

    /// Bytes before the Opus frame in the sub-packet layout.
    static let subPacketAudioOffset = 2 + (2 + 7) + (2 + HapticsFormat.bytesPerReport) + 2  // 79

    /// Largest Opus packet that fits.
    public var maxPacketBytes: Int {
        guard isValid else { return 0 }
        switch layout {
        case .subPackets:
            return min(reportLength - Self.subPacketAudioOffset - (crc ? 4 : 0), 255)
        case .lengthPrefixed:
            let cap = reportLength - payloadOffset - prefixBytes - (crc ? 4 : 0)
            return min(cap, lengthPrefix == .u8 ? 255 : 65_535)
        }
    }

    var prefixBytes: Int { lengthPrefix == .none ? 0 : lengthPrefix == .u8 ? 1 : 2 }

    /// A bounded HID report with room for the complete header, prefix and CRC.
    public var isValid: Bool {
        guard reportID != 0, (1...65_535).contains(reportLength) else { return false }
        switch layout {
        case .subPackets:
            return reportLength > Self.subPacketAudioOffset + (crc ? 4 : 0)
        case .lengthPrefixed:
            guard payloadOffset >= 1, payloadOffset <= reportLength else { return false }
            return reportLength - payloadOffset >= prefixBytes + (crc ? 4 : 0)
                && (!crc || reportLength > 4)
        }
    }
}

/// Builds speaker-audio reports from already-encoded Opus packets. Keeps the
/// 4-bit report sequence and the control sub-packet's running counter.
public struct SpeakerAudioReportBuilder: Sendable {
    public enum BuildError: Error, Sendable, Equatable {
        case packetTooLarge(size: Int, max: Int)
        case badFraming(String)
    }

    public var framing: SpeakerAudioFraming
    public private(set) var sequence: UInt8 = 0
    public private(set) var counter: UInt8 = 0

    public init(framing: SpeakerAudioFraming) {
        self.framing = framing
    }

    /// - Parameters:
    ///   - opusPacket: one encoded frame (200 bytes CBR in the public implementations).
    ///   - haptics: 32 interleaved stereo frames (L, R, …) of 8-bit haptics;
    ///     missing samples are silence. Ignored by the length-prefixed layout.
    ///   - destination: overrides `framing.destination` for this report.
    public mutating func build(opusPacket p: [UInt8], haptics: [Int8] = [],
                               destination: SpeakerAudioFraming.Destination? = nil) throws(BuildError) -> [UInt8] {
        let f = framing
        guard f.isValid else {
            throw .badFraming("reportLength \(f.reportLength) too small for the \(f.layout.rawValue) layout")
        }
        guard p.count <= f.maxPacketBytes else { throw .packetTooLarge(size: p.count, max: f.maxPacketBytes) }
        var r = [UInt8](repeating: 0, count: f.reportLength)
        r[0] = f.reportID
        let seq = sequence & 0x0F, tag = f.tag & 0x0F
        let seqByte = f.sequenceInHighNibble ? (seq << 4 | tag) : (tag << 4 | seq)
        switch f.layout {
        case .subPackets:
            r[1] = seqByte
            var i = 2
            r[i] = f.controlHeader; r[i + 1] = 7; i += 2
            for k in 0..<6 { r[i + k] = k < f.controlPayload.count ? f.controlPayload[k] : 0 }
            r[i + 6] = counter; i += 7
            r[i] = f.hapticsHeader; r[i + 1] = UInt8(HapticsFormat.bytesPerReport); i += 2
            for k in 0..<HapticsFormat.bytesPerReport {
                let s = UInt8(bitPattern: k < haptics.count ? haptics[k] : 0)
                r[i + k] = f.signedHapticSamples ? s : s ^ 0x80
            }
            i += HapticsFormat.bytesPerReport
            r[i] = (destination ?? f.destination).rawValue; r[i + 1] = UInt8(p.count); i += 2
            r.replaceSubrange(i..<(i + p.count), with: p)
        case .lengthPrefixed:
            if f.payloadOffset >= 2 { r[1] = seqByte }
            var i = f.payloadOffset
            switch f.lengthPrefix {
            case .none: break
            case .u8:
                r[i] = UInt8(p.count); i += 1
            case .u16LittleEndian:
                r[i] = UInt8(truncatingIfNeeded: p.count); r[i + 1] = UInt8(truncatingIfNeeded: p.count >> 8); i += 2
            }
            r.replaceSubrange(i..<(i + p.count), with: p)
        }
        if f.crc { CRC32.seal(&r, prefix: .output) }
        sequence = (sequence + 1) & 0x0F
        counter &+= 1
        return r
    }
}

/// One audio frame ready for report 0x36.
public struct SpeakerPacket: Sendable, Hashable {
    public var opus: [UInt8]
    public var destination: SpeakerAudioFraming.Destination
    public init(opus: [UInt8], destination: SpeakerAudioFraming.Destination) {
        self.opus = opus
        self.destination = destination
    }
}

/// Supplies audio frames to the haptics pump, which then sends report 0x36
/// (haptics + audio) instead of 0x32 on its 10.667 ms grid. Called on the
/// pump's real-time thread: must not block or allocate heavily.
public protocol SpeakerPacketSource: AnyObject, Sendable {
    /// The next frame, or nil when no audio stream is active.
    func nextPacket() -> SpeakerPacket?
}
