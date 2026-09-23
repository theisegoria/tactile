// EXPERIMENTAL (gate 6): decode the controller microphone uplink (🔬 lead:
// Opus, 24 kHz) from raw input reports, once `UplinkScanner` has located it.

import AVFAudio
public import Foundation
public import TactileCore

public struct MicUplinkStats: Sendable, CustomStringConvertible {
    public var reportsSeen = 0
    public var packetsDecoded = 0
    public var decodeErrors = 0
    public var framesDecoded = 0

    public var description: String {
        "reports \(reportsSeen), packets decoded \(packetsDecoded), decode errors \(decodeErrors), frames \(framesDecoded)"
    }
}

/// Turns uplink reports into PCM. Not thread-safe; one consumer.
public final class MicUplinkDecoder: @unchecked Sendable {
    public let extractor: UplinkExtractor
    public let format: OpusStreamFormat
    private let decoder: OpusDecoder
    public private(set) var stats = MicUplinkStats()

    public init(extractor: UplinkExtractor, format: OpusStreamFormat = .microphone) throws {
        self.extractor = extractor
        self.format = format
        decoder = try OpusDecoder(format: format)
    }

    /// Decodes the packet in `report`; nil if it is not an uplink report.
    public func process(_ report: [UInt8]) -> [Float]? {
        guard let packet = extractor.packet(from: report) else { return nil }
        stats.reportsSeen += 1
        do {
            let pcm = try decoder.decode(packet)
            stats.packetsDecoded += 1
            stats.framesDecoded += pcm.count / max(format.channels, 1)
            return pcm
        } catch {
            stats.decodeErrors += 1
            return nil
        }
    }

    /// Writes decoded audio from `reports` to a WAV file until `duration` elapses
    /// or the stream ends.
    public func record<S: AsyncSequence & Sendable>(reports: S, to url: URL, duration: Duration) async throws -> MicUplinkStats
    where S.Element == [UInt8] {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels)) else {
            throw OpusCodecError.unsupportedFormat("\(format)")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let deadline = ContinuousClock.now + duration
        for try await report in reports {
            if ContinuousClock.now >= deadline { break }
            guard let pcm = process(report), !pcm.isEmpty else { continue }
            let ch = format.channels, frames = pcm.count / ch
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
                  let d = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            for f in 0..<frames { for c in 0..<ch { d[c][f] = pcm[f * ch + c] } }
            try file.write(from: buf)
        }
        return stats
    }
}
