// Float PCM input at any rate/channel count → 3 kHz stereo into the mixer.

import Foundation

/// Converts incoming float PCM to the haptics format and writes it to a mixer's
/// stream buffer. Not thread-safe: use one instance per producer thread.
public final class PCMInput: @unchecked Sendable {
    public let mixer: HapticsMixer
    public private(set) var inputRate: Double
    private var left: StreamingResampler
    private var right: StreamingResampler
    private var outL: [Float] = []
    private var outR: [Float] = []
    private var interleaved: [Float] = []
    /// Frames dropped because the stream buffer was full.
    public private(set) var droppedFrames = 0

    public init(mixer: HapticsMixer, inputRate: Double) {
        self.mixer = mixer
        self.inputRate = inputRate
        left = StreamingResampler(inputRate: inputRate)
        right = StreamingResampler(inputRate: inputRate)
    }

    /// Resets filters for a new input rate.
    public func reconfigure(inputRate: Double) {
        guard inputRate != self.inputRate else { return }
        self.inputRate = inputRate
        left = StreamingResampler(inputRate: inputRate)
        right = StreamingResampler(inputRate: inputRate)
    }

    /// Filter delay in milliseconds.
    public var latencyMs: Double { left.latencyOutputSamples / 3.0 }

    /// Feeds planar channels (1 = mono, duplicated to both actuators; 2+ = first two used).
    /// Returns the number of 3 kHz frames written.
    @discardableResult
    public func feed(channels: [UnsafeBufferPointer<Float>]) -> Int {
        guard let first = channels.first else { return 0 }
        let second = channels.count > 1 ? channels[1] : first
        outL.removeAll(keepingCapacity: true)
        outR.removeAll(keepingCapacity: true)
        left.process(first, into: &outL)
        right.process(second, into: &outR)
        let n = min(outL.count, outR.count)
        interleaved.removeAll(keepingCapacity: true)
        interleaved.reserveCapacity(n * 2)
        for i in 0..<n {
            interleaved.append(outL[i])
            interleaved.append(outR[i])
        }
        let written = mixer.stream.write(interleaved) / 2
        droppedFrames += n - written
        return written
    }

    /// Feeds interleaved samples with `channelCount` channels.
    @discardableResult
    public func feed(interleaved samples: [Float], channelCount: Int) -> Int {
        let cc = max(channelCount, 1)
        let frames = samples.count / cc
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            l[f] = samples[f * cc]
            r[f] = cc > 1 ? samples[f * cc + 1] : samples[f * cc]
        }
        return l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in feed(channels: [lp, rp]) } }
    }
}
