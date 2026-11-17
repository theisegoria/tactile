// Offline rendering of a haptic pattern to per-actuator PCM at the haptics
// rate (3 kHz), for waveform previews and for sample-accurate playback.
// Deterministic: the same pattern and clips always give the same samples.

import AVFAudio
public import Foundation
public import TactileCore

/// Decoded audio handed to the renderer: planar float channels at `sampleRate`.
public struct DecodedAudioClip: Sendable, Hashable {
    public var sampleRate: Double
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
}

/// Loads the audio a clip references. Throwing fails the render.
public typealias HapticClipLoader = @Sendable (HapticAudioClip) throws -> DecodedAudioClip

/// Rendered haptic PCM: one float channel per actuator (0 = left grip,
/// 1 = right grip; UNVERIFIED channel mapping, see TESTING.md), −1…1.
public struct HapticPreview: Sendable, Hashable {
    public let sampleRate: Double
    public var left: [Float]
    public var right: [Float]

    public init(sampleRate: Double = HapticsFormat.sampleRate, left: [Float], right: [Float]) {
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    public var frameCount: Int { min(left.count, right.count) }
    public var duration: Double { Double(frameCount) / sampleRate }

    /// Interleaved stereo, as the mixer's stream expects.
    public var interleaved: [Float] {
        var out = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            out[2 * i] = left[i]
            out[2 * i + 1] = right[i]
        }
        return out
    }

    /// The signed 8-bit samples the controller would receive (no dither, so
    /// the result is deterministic).
    public func quantized() -> (left: [Int8], right: [Int8]) {
        var q = Quantizer8(dither: false)
        return (left.map { q.quantize($0) }, right.map { q.quantize($0) })
    }

    /// Min/max per bucket for drawing a waveform of `bucketCount` columns.
    public func peaks(bucketCount: Int, channel: HapticSide = .both) -> [(min: Float, max: Float)] {
        let n = frameCount
        let buckets = max(1, bucketCount)
        guard n > 0 else { return Array(repeating: (0, 0), count: buckets) }
        return (0..<buckets).map { b in
            let lo = b * n / buckets, hi = max(lo + 1, (b + 1) * n / buckets)
            var mn: Float = 0, mx: Float = 0
            for i in lo..<min(hi, n) {
                let v: Float
                switch channel {
                case .left: v = left[i]
                case .right: v = right[i]
                case .both: v = abs(left[i]) >= abs(right[i]) ? left[i] : right[i]
                }
                mn = min(mn, v)
                mx = max(mx, v)
            }
            return (mn, mx)
        }
    }
}

public enum HapticPatternRenderer {
    /// Renders `pattern` (muted tracks excluded) without any device.
    /// - Parameters:
    ///   - gain: master gain applied before clipping, 0…1 like `HapticsMixer.setGain`.
    ///   - clipLoader: decodes referenced audio; `fileClipLoader(relativeTo:)` reads files.
    ///     Not called when the pattern has no audio events.
    public static func renderOffline(_ pattern: HapticPattern, gain: Float = 1,
                                     clipLoader: HapticClipLoader = { clip in
                                         throw HapticPattern.Failure.unreadableClip(path: clip.path, reason: "no clip loader")
                                     }) throws -> HapticPreview {
        let rate = HapticsFormat.sampleRate
        let maxFrames = Int(HapticPattern.maximumDuration * rate)
        func frame(_ t: Double) -> Int { min(maxFrames, max(0, Int((t * rate).rounded()))) }

        // Gather valid events in a stable order.
        var effects: [(start: Int, effect: HapticEffect, side: HapticSide, seed: UInt32)] = []
        var clips: [(start: Int, left: [Float], right: [Float])] = []
        var rumbles: [(start: Int, rumble: Rumble, duration: Double)] = []
        var index: UInt32 = 0
        for track in pattern.tracks where !track.isMuted {
            for e in track.events {
                index &+= 1
                guard e.time.isFinite, e.time >= 0, e.time <= HapticPattern.maximumDuration else { continue }
                switch e.action {
                case let .effect(effect, side):
                    effects.append((frame(e.time), effect, side, 0x9E37_79B9 &* index))
                case let .audio(clip):
                    let (l, r) = try resampledClip(clip, loader: clipLoader)
                    clips.append((frame(e.time), l, r))
                case let .rumble(r, d):
                    rumbles.append((frame(e.time), r, d))
                case .trigger, .lightbar:
                    break
                }
            }
        }

        // Voices, rendered once (their length decides the total).
        var voiceSamples: [(start: Int, side: HapticSide, samples: [Float])] = []
        for e in effects {
            var v = Voice(effect: e.effect, side: e.side, sampleRate: Float(rate), seed: e.seed)
            let len = min(v.length, maxFrames - e.start)
            guard len > 0 else { continue }
            var s = [Float](repeating: 0, count: len)
            for i in 0..<len { s[i] = v.next() }
            voiceSamples.append((e.start, e.side, s))
        }

        var end = 0
        for v in voiceSamples { end = max(end, v.start + v.samples.count) }
        for c in clips { end = max(end, c.start + max(c.left.count, c.right.count)) }
        for r in rumbles where r.duration > 0 && r.duration.isFinite {
            end = max(end, r.start + Int((r.duration * rate).rounded()))
        }
        // A held rumble with nothing after it still lasts until its own start.
        for r in rumbles { end = max(end, r.start) }
        end = min(end, maxFrames)

        var left = [Float](repeating: 0, count: end)
        var right = [Float](repeating: 0, count: end)

        for v in voiceSamples {
            for (i, x) in v.samples.enumerated() where v.start + i < end {
                switch v.side {
                case .left: left[v.start + i] += x
                case .right: right[v.start + i] += x
                case .both: left[v.start + i] += x; right[v.start + i] += x
                }
            }
        }
        for c in clips {
            for i in 0..<min(c.left.count, end - c.start) where c.start + i >= 0 { left[c.start + i] += c.left[i] }
            for i in 0..<min(c.right.count, end - c.start) where c.start + i >= 0 { right[c.start + i] += c.right[i] }
        }

        // Rumble: the mixer's emulation (55 Hz on both coils, 160 Hz on the
        // right), one segment per event until its duration or the next event.
        let sortedRumble = rumbles.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        for (k, r) in sortedRumble.enumerated() {
            let next = k + 1 < sortedRumble.count ? sortedRumble[k + 1].start : end
            var stop = next
            if r.duration > 0, r.duration.isFinite { stop = min(stop, r.start + Int((r.duration * rate).rounded())) }
            stop = min(stop, end)
            guard stop > r.start, r.rumble != .off else { continue }
            let lg = Float(r.rumble.left) / 255, rg = Float(r.rumble.right) / 255
            let dl = 2 * Double.pi * Double(HapticsMixer.rumbleLeftHz) / rate
            let dr = 2 * Double.pi * Double(HapticsMixer.rumbleRightHz) / rate
            for i in r.start..<stop {
                let n = Double(i - r.start)
                let heavy = lg * 0.8 * Float(sin(n * dl))
                let light = rg * 0.6 * Float(sin(n * dr))
                left[i] += heavy
                right[i] += heavy + light
            }
        }

        let g = gain.isNaN ? 0 : min(max(gain, 0), 1)
        func clip(_ x: Float) -> Float { x.isNaN ? 0 : min(max(x * g, -1), 1) }
        for i in 0..<end {
            left[i] = clip(left[i])
            right[i] = clip(right[i])
        }
        return HapticPreview(sampleRate: rate, left: left, right: right)
    }

    /// Decodes, trims, applies gain and side, and resamples a clip to 3 kHz.
    static func resampledClip(_ clip: HapticAudioClip, loader: HapticClipLoader) throws -> ([Float], [Float]) {
        let decoded = try loader(clip)
        guard decoded.sampleRate.isFinite, StreamingResampler.isSupported(rate: decoded.sampleRate),
              let first = decoded.channels.first else { return ([], []) }
        let second = decoded.channels.count > 1 ? decoded.channels[1] : first
        let n = min(first.count, second.count)
        let startTrim = clip.trimStart.isFinite ? max(0, clip.trimStart) : 0
        let lo = min(n, Int((startTrim * decoded.sampleRate).rounded()))
        var hi = n
        if let te = clip.trimEnd, te.isFinite { hi = max(lo, min(n, Int((te * decoded.sampleRate).rounded()))) }
        let g = clip.gain.isNaN ? 0 : min(max(clip.gain, 0), 4)
        var l = Array(first[lo..<hi]), r = Array(second[lo..<hi])
        switch clip.side {
        case .both: break
        case .left, .right:
            let mono = zip(l, r).map { ($0 + $1) / 2 }
            if clip.side == .left { l = mono; r = [Float](repeating: 0, count: mono.count) } else { r = mono; l = [Float](repeating: 0, count: mono.count) }
        }
        func resample(_ x: [Float]) -> [Float] {
            var rs = StreamingResampler(inputRate: decoded.sampleRate)
            var out: [Float] = []
            rs.process(x, into: &out)
            rs.flush(into: &out)
            // Output k is centred on input time k / 3000 s (the filter delay
            // only postpones when it is produced), so nothing is dropped.
            return out.map { $0 * g }
        }
        return (resample(l), resample(r))
    }

    /// A loader that reads clips with `AVAudioFile`. Relative paths resolve
    /// against `base` (normally the pattern file's folder).
    public static func fileClipLoader(relativeTo base: URL?) -> HapticClipLoader {
        { clip in
            let url: URL
            if clip.path.hasPrefix("/") || base == nil {
                url = URL(fileURLWithPath: clip.path)
            } else {
                url = base!.appendingPathComponent(clip.path)
            }
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frames = AVAudioFrameCount(min(file.length, Int64(HapticPattern.maximumDuration * format.sampleRate)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else {
                    throw HapticPattern.Failure.unreadableClip(path: clip.path, reason: "cannot allocate buffer")
                }
                try file.read(into: buffer, frameCount: frames)
                guard let data = buffer.floatChannelData else {
                    throw HapticPattern.Failure.unreadableClip(path: clip.path, reason: "not float PCM")
                }
                let count = Int(buffer.frameLength)
                let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) }
                return DecodedAudioClip(sampleRate: format.sampleRate, channels: channels)
            } catch let e as HapticPattern.Failure {
                throw e
            } catch {
                throw HapticPattern.Failure.unreadableClip(path: clip.path, reason: "\(error)")
            }
        }
    }
}
