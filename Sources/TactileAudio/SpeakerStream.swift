// EXPERIMENTAL (gate 6): stream an audio file to the controller's speaker or
// headphone jack as Opus in report 0x36 (🔬 lead), paced at one 10 ms packet
// per report.

import AVFAudio
public import Foundation
public import TactileCore

public struct SpeakerStreamStats: Sendable, CustomStringConvertible {
    public var packetsSent = 0
    public var packetsDroppedOversize = 0
    public var sendFailures = 0
    public var largestPacket = 0
    public var maxLatenessMs = 0.0
    public var lastError: String?

    public var description: String {
        "sent \(packetsSent), dropped (too large) \(packetsDroppedOversize), send failures \(sendFailures), "
            + "largest packet \(largestPacket) B, max lateness \(String(format: "%.2f", maxLatenessMs)) ms"
            + (lastError.map { ", last error: \($0)" } ?? "")
    }
}

public final class SpeakerStream: Sendable {
    public typealias Send = @Sendable ([UInt8]) async throws -> Void

    public let framing: SpeakerAudioFraming
    public let format: OpusStreamFormat
    public let bitRate: Int
    private let send: Send

    /// - Parameters:
    ///   - framing: report layout; take `reportLength` from the controller's descriptor.
    ///   - bitRate: pick one whose packets fit `framing.maxPacketBytes`
    ///     (96 kb/s ≈ 120 B per 10 ms packet).
    ///   - send: delivers one finished report (e.g. `DeviceConnection.sendExperimentalOutputReport`).
    public init(framing: SpeakerAudioFraming, format: OpusStreamFormat = .speaker, bitRate: Int = 96_000, send: @escaping Send) {
        self.framing = framing
        self.format = format
        self.bitRate = bitRate
        self.send = send
    }

    /// Plays `url` in real time. Returns when done or when the task is cancelled.
    public func play(url: URL, gain: Float = 1) async throws -> SpeakerStreamStats {
        let source = try PCMFileSource(url: url, sampleRate: format.sampleRate, channels: format.channels)
        return try await play(chunks: source.chunks(frames: format.framesPerPacket, gain: gain))
    }

    /// Plays pre-chunked interleaved PCM (each chunk one packet's worth).
    public func play<S: Sequence>(chunks: S) async throws -> SpeakerStreamStats where S.Element == [Float] {
        let encoder = try OpusEncoder(format: format, bitRate: bitRate)
        var builder = SpeakerAudioReportBuilder(framing: framing)
        var stats = SpeakerStreamStats()
        let clock = ContinuousClock()
        let period = Duration.microseconds(Int64(format.frameMilliseconds * 1000))
        let start = clock.now
        var k = 0
        func deliver(_ packets: [[UInt8]]) async throws {
            for p in packets {
                stats.largestPacket = max(stats.largestPacket, p.count)
                let report: [UInt8]
                do {
                    report = try builder.build(opusPacket: p)
                } catch {
                    stats.packetsDroppedOversize += 1
                    continue
                }
                let deadline = start + period * k
                k += 1
                if clock.now < deadline { try await clock.sleep(until: deadline) }
                let late = clock.now - deadline
                stats.maxLatenessMs = max(stats.maxLatenessMs, Double(late.components.attoseconds) / 1e15 + Double(late.components.seconds) * 1000)
                do {
                    try await send(report)
                    stats.packetsSent += 1
                } catch {
                    stats.sendFailures += 1
                    stats.lastError = "\(error)"
                }
            }
        }
        for chunk in chunks {
            try Task.checkCancellation()
            try await deliver(try encoder.encode(interleaved: chunk))
        }
        try await deliver(try encoder.flush())
        return stats
    }
}

/// Reads an audio file as float PCM at a given rate, mapping channels
/// (mono is duplicated; beyond `channels` are dropped).
struct PCMFileSource {
    let file: AVAudioFile
    let target: AVAudioFormat
    let channels: Int

    init(url: URL, sampleRate: Double, channels: Int) throws {
        file = try AVAudioFile(forReading: url)
        let inCh = file.processingFormat.channelCount
        guard let t = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: inCh) else {
            throw OpusCodecError.unsupportedFormat("\(sampleRate) Hz")
        }
        target = t
        self.channels = channels
    }

    /// Converts the whole file up front (research tool; files are short).
    func chunks(frames n: Int, gain: Float) throws -> [[Float]] {
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw OpusCodecError.unsupportedFormat("cannot convert \(file.processingFormat)")
        }
        let inCap: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap) else {
            throw OpusCodecError.conversionFailed("buffer")
        }
        var planar: [[Float]] = Array(repeating: [], count: Int(target.channelCount))
        var done = false
        while !done {
            let outCap = AVAudioFrameCount(Double(inCap) * target.sampleRate / file.processingFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { break }
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, s in
                do {
                    try file.read(into: inBuf, frameCount: inCap)
                } catch {
                    s.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 { s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return inBuf
            }
            if let d = out.floatChannelData {
                for c in 0..<planar.count { planar[c] += UnsafeBufferPointer(start: d[c], count: Int(out.frameLength)) }
            }
            if status == .endOfStream || status == .error || out.frameLength == 0 { done = true }
            if status == .error { throw OpusCodecError.conversionFailed(err?.localizedDescription ?? "resample") }
        }
        let frames = planar.first?.count ?? 0
        var result: [[Float]] = []
        var f = 0
        while f < frames {
            let m = min(n, frames - f)
            var chunk = [Float](repeating: 0, count: m * channels)
            for i in 0..<m {
                for c in 0..<channels {
                    let src = planar[min(c, planar.count - 1)][f + i] * gain
                    chunk[i * channels + c] = max(-1, min(1, src))
                }
            }
            result.append(chunk)
            f += m
        }
        return result
    }
}
