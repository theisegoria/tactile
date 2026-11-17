import AVFAudio
import Foundation
import Tactile

/// Renders a composition's actuator tracks offline at the controller's 3 kHz
/// haptics rate, with no device. The parametric math mirrors the library's
/// `Voice` synthesis (TactileHaptics/Effects.swift); audio clips are decoded
/// and resampled here; rumble becomes a low-frequency vibration.
struct ComposerMix: Sendable {
    static let sampleRate = HapticsFormat.sampleRate
    var left: [Float] = []
    var right: [Float] = []
    /// Samples that reached full scale and were clamped.
    var clipped = 0
    var duration: Double { Double(left.count) / Self.sampleRate }
    var isSilent: Bool { !left.contains { $0 != 0 } && !right.contains { $0 != 0 } }

    /// Min/max pairs for drawing, one per bucket.
    func envelope(_ samples: [Float], buckets: Int) -> [(Float, Float)] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        return stride(from: 0, to: samples.count, by: size).map { i in
            let slice = samples[i..<min(samples.count, i + size)]
            return (slice.min() ?? 0, slice.max() ?? 0)
        }
    }
}

enum ComposerRenderer {
    /// Decoded clips at 3 kHz mono, keyed by path; shared across renders.
    @MainActor static var clipCache: [String: [Float]] = [:]

    @MainActor
    static func render(_ doc: ComposerDocument, length: Double? = nil) -> ComposerMix {
        let rate = ComposerMix.sampleRate
        let seconds = min(ComposerDocument.maximumDuration, max(0, length ?? max(doc.duration, doc.contentEnd)))
        let count = Int(seconds * rate)
        var mix = ComposerMix(left: [Float](repeating: 0, count: count), right: [Float](repeating: 0, count: count))
        guard count > 0 else { return mix }
        for track in doc.tracks where track.kind.isActuator && !track.muted {
            for event in track.events {
                let u = event.id.uuid
                let seed = (UInt32(u.0) | UInt32(u.1) << 8 | UInt32(u.2) << 16 | UInt32(u.3) << 24) | 1
                if case .rumble(let r) = event.content {
                    // Mirrors HapticsMixer's emulation: the heavy (left) motor
                    // drives both coils at 55 Hz, the light (right) motor the
                    // right coil at 160 Hz.
                    let heavy = track.kind == .leftActuator
                    let level = Float(max(0, min(255, r.level))) / 255 * (heavy ? 0.8 : 0.6)
                    let hz = heavy ? HapticsMixer.rumbleLeftHz : HapticsMixer.rumbleRightHz
                    addRumble(level: level, hz: hz, from: event.start, to: event.end, rate: rate, into: &mix.right)
                    if heavy { addRumble(level: level, hz: hz, from: event.start, to: event.end, rate: rate, into: &mix.left) }
                } else if track.kind == .leftActuator { add(event, into: &mix.left, rate: rate, seed: seed) }
                else { add(event, into: &mix.right, rate: rate, seed: seed) }
            }
        }
        for i in 0..<count {
            if abs(mix.left[i]) > 1 { mix.left[i] = mix.left[i] > 0 ? 1 : -1; mix.clipped += 1 }
            if abs(mix.right[i]) > 1 { mix.right[i] = mix.right[i] > 0 ? 1 : -1; mix.clipped += 1 }
        }
        return mix
    }

    @MainActor
    private static func add(_ event: ComposerEvent, into buffer: inout [Float], rate: Double, seed: UInt32) {
        let first = max(0, Int(event.start * rate))
        let last = min(buffer.count, Int(event.end * rate))
        guard last > first else { return }
        switch event.content {
        case .parametric(let p):
            if p.kind.isOneShot {
                let interval = p.repeatInterval > 0.005 ? p.repeatInterval : event.duration + 1
                var onset = event.start
                var n: UInt32 = 0
                while onset < event.end {
                    let samples = synthesize(p.effect(duration: 0), rate: rate, seed: seed &+ n)
                    let at = Int(onset * rate)
                    for (k, s) in samples.enumerated() where at + k < last && at + k >= 0 { buffer[at + k] += s }
                    onset += interval; n &+= 1
                }
            } else {
                let samples = synthesize(p.effect(duration: event.duration), rate: rate, seed: seed)
                for (k, s) in samples.enumerated() where first + k < last { buffer[first + k] += s }
            }
        case .audioClip(let clip):
            guard let decoded = decodedClip(clip.path) else { return }
            let offset = Int(max(0, clip.trim) * rate)
            for i in first..<last {
                let j = offset + (i - first)
                guard j < decoded.count else { break }
                buffer[i] += decoded[j] * clip.gain
            }
        case .rumble, .trigger, .lightbar, .unsupported:
            break
        }
    }

    private static func addRumble(level: Float, hz: Float, from start: Double, to end: Double, rate: Double, into buffer: inout [Float]) {
        let first = max(0, Int(start * rate)), last = min(buffer.count, Int(end * rate))
        guard last > first else { return }
        for i in first..<last {
            let t = Float(i - first) / Float(rate)
            buffer[i] += level * sin(2 * .pi * hz * t)
        }
    }

    /// One voice of `effect`, sample for sample like the library's `Voice`.
    static func synthesize(_ effect: HapticEffect, rate: Double, seed: UInt32) -> [Float] {
        let sampleRate = Float(rate)
        let d = effect.duration
        let seconds = d.isNaN ? 0 : min(max(d, 0), ComposerDocument.maximumDuration)
        let length = max(1, Int(seconds * rate))
        var rng = seed == 0 ? 0x9E37_79B9 : seed
        func unit() -> Float {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            return Float(rng) / Float(UInt32.max) - 0.5
        }
        var out = [Float](repeating: 0, count: length)
        var nextGrain = 0, grainStart = 0
        for position in 0..<length {
            let t = Float(position) / sampleRate
            switch effect {
            case .click(let a, let f):
                out[position] = a * sin(2 * .pi * f * t) * exp(-t / 0.004)
            case .detent(let a, let f):
                let env = 0.5 - 0.5 * cos(2 * .pi * Float(position) / Float(length))
                out[position] = a * env * sin(2 * .pi * f * t)
            case .texture(let a, let grains, _):
                if position >= nextGrain {
                    let interval = sampleRate / (grains.isNaN ? 1 : max(grains, 1))
                    grainStart = position
                    nextGrain = position + max(1, Int(interval * (0.6 + 0.8 * (unit() + 0.5))))
                }
                let since = Float(position - grainStart) / sampleRate
                out[position] = a * 0.8 * sin(2 * .pi * 200 * since) * exp(-since / 0.006)
            case .impact(let a):
                let body = sin(2 * .pi * 70 * t) * exp(-t / 0.045)
                let transient = unit() * 2 * exp(-t / 0.006)
                out[position] = a * (0.85 * body + 0.35 * transient)
            case .tone(let a, let f, _):
                let fade = min(1, Float(position) / 15, Float(length - position) / 15)
                out[position] = a * fade * sin(2 * .pi * f * t)
            }
        }
        return out
    }

    /// Decodes an audio file to mono at 3 kHz (box-filtered decimation).
    @MainActor
    static func decodedClip(_ path: String) -> [Float]? {
        if let cached = clipCache[path] { return cached }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let format = file.processingFormat
        let maxFrames = AVAudioFrameCount(min(Double(file.length), format.sampleRate * ComposerDocument.maximumDuration))
        guard maxFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
              (try? file.read(into: buffer, frameCount: maxFrames)) != nil,
              let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), channels = Int(format.channelCount)
        let ratio = format.sampleRate / ComposerMix.sampleRate
        let outCount = Int(Double(frames) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let a = Int(Double(i) * ratio), b = max(a + 1, min(frames, Int(Double(i + 1) * ratio)))
            var sum: Float = 0
            for c in 0..<channels { for k in a..<b { sum += data[c][k] } }
            out[i] = sum / Float((b - a) * channels)
        }
        clipCache[path] = out
        return out
    }

    /// Writes the mix as a 16-bit stereo WAV at 3 kHz (left, right actuator).
    static func writeWAV(_ mix: ComposerMix, to url: URL) throws {
        let frames = min(mix.left.count, mix.right.count)
        let rate = UInt32(ComposerMix.sampleRate)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(frames * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(payload)
        data.reserveCapacity(data.count + Int(payload))
        for i in 0..<frames {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, mix.left[i])) * 32767)))
            u16(UInt16(bitPattern: Int16(max(-1, min(1, mix.right[i])) * 32767)))
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Output state over time

    /// The trigger effects in force at `time`, per side (nil = no event).
    static func triggers(in doc: ComposerDocument, at time: Double) -> (left: TriggerDesign?, right: TriggerDesign?) {
        guard let track = doc.track(.triggers), !track.muted else { return (nil, nil) }
        var left: TriggerDesign?, right: TriggerDesign?
        for event in track.events.sorted(by: { $0.start < $1.start }) where event.start <= time && time < event.end {
            guard case .trigger(let change) = event.content else { continue }
            if change.side != .right { left = change.design }
            if change.side != .left { right = change.design }
        }
        return (left, right)
    }

    /// The lightbar colour at `time`, with fades applied.
    static func lightbar(in doc: ComposerDocument, at time: Double) -> ComposerEvent.LightbarKey? {
        guard let track = doc.track(.lightbar), !track.muted else { return nil }
        let keys = track.events.sorted { $0.start < $1.start }
        guard let index = keys.lastIndex(where: { $0.start <= time && time < $0.end }),
              case .lightbar(let key) = keys[index].content else { return nil }
        guard key.fade > 0, time - keys[index].start < key.fade, index > 0,
              case .lightbar(let previous) = keys[index - 1].content else { return key }
        let t = (time - keys[index].start) / key.fade
        func mixc(_ a: Int, _ b: Int) -> Int { Int(Double(a) + (Double(b) - Double(a)) * t) }
        return ComposerEvent.LightbarKey(red: mixc(previous.red, key.red), green: mixc(previous.green, key.green), blue: mixc(previous.blue, key.blue))
    }

    /// Discrete output changes (time, state) for the trigger and lightbar
    /// tracks, for a playback executor that can send them on schedule.
    static func outputKeys(for doc: ComposerDocument) -> [(time: Double, state: OutputState)] {
        var times = Set<Double>([0])
        for kind in [ComposerTrack.Kind.triggers, .lightbar] {
            for event in doc.track(kind)?.events ?? [] { times.insert(event.start); times.insert(event.end) }
        }
        return times.sorted().compactMap { time in
            let t = triggers(in: doc, at: time)
            var state = OutputState()
            state.leftTrigger = (try? (t.left ?? .off).effect()) ?? .off
            state.rightTrigger = (try? (t.right ?? .off).effect()) ?? .off
            if let key = lightbar(in: doc, at: time) { state.lightbar = key.color }
            return (time, state)
        }
    }
}
