// EXPERIMENTAL (gate 6): Opus encode/decode using macOS's built-in codec
// (AudioToolbox, kAudioFormatOpus) through AVAudioConverter. No third-party
// dependency. One packet = one 10 ms frame.

import AVFAudio
import Foundation

public enum OpusCodecError: Error, Sendable, Equatable {
    case unsupportedFormat(String)
    case conversionFailed(String)
}

/// Opus stream parameters.
public struct OpusStreamFormat: Sendable, Hashable, Codable {
    public var sampleRate: Double
    public var channels: Int
    /// Frame duration in milliseconds (2.5, 5, 10, 20, 40 or 60).
    public var frameMilliseconds: Double

    public init(sampleRate: Double, channels: Int, frameMilliseconds: Double = 10) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameMilliseconds = frameMilliseconds
    }

    /// Speaker lead (🔬): 48 kHz stereo, 10 ms (CELT fullband).
    public static let speaker = OpusStreamFormat(sampleRate: 48000, channels: 2)
    /// Microphone lead (🔬): 24 kHz mono, 10 ms.
    public static let microphone = OpusStreamFormat(sampleRate: 24000, channels: 1)

    public var framesPerPacket: Int { Int((sampleRate * frameMilliseconds / 1000).rounded()) }

    func avFormats() throws(OpusCodecError) -> (pcm: AVAudioFormat, opus: AVAudioFormat) {
        var d = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard channels >= 1, channels <= 2, framesPerPacket > 0,
              let opus = AVAudioFormat(streamDescription: &d),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else { throw .unsupportedFormat("\(sampleRate) Hz, \(channels) ch, \(frameMilliseconds) ms") }
        return (pcm, opus)
    }
}

/// Encodes float PCM into Opus packets. Not thread-safe; one producer.
public final class OpusEncoder: @unchecked Sendable {
    public let format: OpusStreamFormat
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private var pending: [[Float]]  // per channel

    /// - Parameter bitRate: bits per second; snapped to the nearest bitrate the
    ///   system encoder supports. Lower rates give smaller packets.
    public init(format: OpusStreamFormat = .speaker, bitRate: Int = 96_000) throws(OpusCodecError) {
        self.format = format
        (pcm, opus) = try format.avFormats()
        guard let c = AVAudioConverter(from: pcm, to: opus) else {
            throw .unsupportedFormat("no system Opus encoder for \(format)")
        }
        if let rates = c.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty {
            c.bitRate = rates.min { abs($0 - bitRate) < abs($1 - bitRate) } ?? bitRate
        } else {
            c.bitRate = bitRate
        }
        converter = c
        pending = Array(repeating: [], count: format.channels)
    }

    public var bitRate: Int { converter.bitRate }
    public var maximumPacketSize: Int { converter.maximumOutputPacketSize }

    /// Queues interleaved samples and returns every complete packet.
    public func encode(interleaved samples: [Float]) throws(OpusCodecError) -> [[UInt8]] {
        let ch = format.channels
        for (i, x) in samples.enumerated() { pending[i % ch].append(x.isFinite ? x : 0) }
        var packets: [[UInt8]] = []
        let n = format.framesPerPacket
        while pending[0].count >= n {
            packets.append(contentsOf: try encodeOne(frames: n))
        }
        return packets
    }

    /// Pads the remainder with silence and encodes it.
    public func flush() throws(OpusCodecError) -> [[UInt8]] {
        guard !pending[0].isEmpty else { return [] }
        let n = format.framesPerPacket
        for c in pending.indices { pending[c] += [Float](repeating: 0, count: n - pending[c].count) }
        return try encodeOne(frames: n)
    }

    private func encodeOne(frames n: Int) throws(OpusCodecError) -> [[UInt8]] {
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(n)),
              let data = buf.floatChannelData else { throw .conversionFailed("PCM buffer allocation") }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<format.channels {
            for i in 0..<n { data[c][i] = pending[c][i] }
            pending[c].removeFirst(n)
        }
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 4, maximumPacketSize: max(converter.maximumOutputPacketSize, 1))
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return buf
        }
        if status == .error { throw .conversionFailed(err?.localizedDescription ?? "encode failed") }
        return Self.packets(out)
    }

    static func packets(_ b: AVAudioCompressedBuffer) -> [[UInt8]] {
        guard let descs = b.packetDescriptions else { return [] }
        let base = b.data.assumingMemoryBound(to: UInt8.self)
        return (0..<Int(b.packetCount)).map { i in
            let d = descs[i]
            return Array(UnsafeBufferPointer(start: base + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
        }
    }
}

/// Decodes Opus packets into interleaved float PCM. Not thread-safe; one consumer.
public final class OpusDecoder: @unchecked Sendable {
    public let format: OpusStreamFormat
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat

    public init(format: OpusStreamFormat = .microphone) throws(OpusCodecError) {
        self.format = format
        (pcm, opus) = try format.avFormats()
        guard let c = AVAudioConverter(from: opus, to: pcm) else {
            throw .unsupportedFormat("no system Opus decoder for \(format)")
        }
        converter = c
    }

    /// Decodes one packet. Malformed packets throw; the decoder stays usable.
    public func decode(_ packet: [UInt8]) throws(OpusCodecError) -> [Float] {
        guard !packet.isEmpty else { return [] }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        // A packet can hold up to 120 ms.
        let capacity = AVAudioFrameCount(format.sampleRate * 0.12)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else {
            throw .conversionFailed("PCM buffer allocation")
        }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return input
        }
        if status == .error { throw .conversionFailed(err?.localizedDescription ?? "decode failed") }
        guard let data = out.floatChannelData else { return [] }
        let frames = Int(out.frameLength), ch = format.channels
        var interleaved = [Float](repeating: 0, count: frames * ch)
        for f in 0..<frames { for c in 0..<ch { interleaved[f * ch + c] = data[c][f] } }
        return interleaved
    }
}
