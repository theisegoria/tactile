// Mixes the streamed PCM, parametric voices and rumble emulation into one
// 3 kHz stereo signal, rendered in 32-frame blocks by the pump.

import Foundation
import Synchronization
public import TactileCore

public final class HapticsMixer: @unchecked Sendable {
    public let sampleRate: Float = Float(HapticsFormat.sampleRate)
    /// Interleaved stereo PCM at 3 kHz (from AudioTapSource / `enqueue`).
    public let stream: SPSCRingBuffer

    private struct Shared {
        var voices: [Voice] = []
        var rumble = Rumble.off
        var gain: Float = 1
        var streamGain: Float = 1
        var seed: UInt32 = 1
    }
    private let shared = Mutex(Shared())
    private var rumblePhase: (Float, Float) = (0, 0)
    private var quantizer = Quantizer8()
    private var scratch: UnsafeMutablePointer<Float>

    /// Frequencies used to emulate the legacy rumble motors on the voice coils.
    public static let rumbleLeftHz: Float = 55
    public static let rumbleRightHz: Float = 160

    public init(streamCapacityFrames: Int = 3000) {  // 1 s of buffer
        stream = SPSCRingBuffer(capacity: streamCapacityFrames * 2)
        scratch = .allocate(capacity: HapticsFormat.bytesPerReport)
    }

    deinit { scratch.deallocate() }

    /// Master gain 0…1.
    public func setGain(_ g: Float) { shared.withLock { $0.gain = max(0, min(g, 1)) } }
    public func setStreamGain(_ g: Float) { shared.withLock { $0.streamGain = max(0, min(g, 4)) } }

    /// Plays a parametric effect. Thread-safe; callable from any thread.
    public func play(_ effect: HapticEffect, side: HapticSide = .both) {
        shared.withLock { s in
            s.seed &+= 0x9E37_79B9
            s.voices.append(Voice(effect: effect, side: side, sampleRate: sampleRate, seed: s.seed))
            if s.voices.count > 32 { s.voices.removeFirst(s.voices.count - 32) }
        }
    }

    /// Emulates rumble motors as low-frequency tones on the voice coils. This is
    /// how rumble requests are honoured while audio haptics own the actuators.
    public func setRumble(_ r: Rumble) { shared.withLock { $0.rumble = r } }

    public func stopAll() {
        shared.withLock { $0.voices.removeAll(); $0.rumble = .off }
        stream.clear()
    }

    /// Renders one report's worth (32 stereo frames) of signed 8-bit samples.
    /// Returns the number of stream frames that were missing (underrun).
    /// Missing stream audio is replaced by silence, never by stale data.
    public func render(into out: inout [Int8]) -> Int {
        let n = HapticsFormat.framesPerReport
        let got = stream.read(into: scratch, count: n * 2)
        for i in got..<(n * 2) { scratch[i] = 0 }
        let underrunFrames = (n * 2 - got) / 2

        var s = shared.withLock { s -> Shared in
            let copy = s
            s.voices.removeAll()
            return copy
        }
        let lg = Float(s.rumble.left) / 255, rg = Float(s.rumble.right) / 255
        let dl = 2 * Float.pi * Self.rumbleLeftHz / sampleRate
        let dr = 2 * Float.pi * Self.rumbleRightHz / sampleRate
        if out.count != n * 2 { out = [Int8](repeating: 0, count: n * 2) }
        for f in 0..<n {
            var l = scratch[2 * f] * s.streamGain
            var r = scratch[2 * f + 1] * s.streamGain
            for v in s.voices.indices where !s.voices[v].finished {
                let x = s.voices[v].next()
                switch s.voices[v].side {
                case .left: l += x
                case .right: r += x
                case .both: l += x; r += x
                }
            }
            if lg > 0 || rg > 0 {
                // Heavy motor: both coils at a low frequency; light motor: right coil.
                let heavy = lg * 0.8 * sin(rumblePhase.0)
                let light = rg * 0.6 * sin(rumblePhase.1)
                l += heavy
                r += heavy + light
                rumblePhase.0 += dl
                rumblePhase.1 += dr
                if rumblePhase.0 > 2 * .pi { rumblePhase.0 -= 2 * .pi }
                if rumblePhase.1 > 2 * .pi { rumblePhase.1 -= 2 * .pi }
            }
            out[2 * f] = quantizer.quantize(softClip(l * s.gain))
            out[2 * f + 1] = quantizer.quantize(softClip(r * s.gain))
        }
        // Return unfinished voices (others may have been added meanwhile).
        s.voices.removeAll { $0.finished }
        if !s.voices.isEmpty {
            let remaining = s.voices
            shared.withLock { $0.voices.insert(contentsOf: remaining, at: 0) }
        }
        return underrunFrames
    }

    /// True when nothing is playing (no voices, no rumble, empty stream).
    public var isIdle: Bool {
        stream.availableToRead == 0 && shared.withLock { $0.voices.isEmpty && $0.rumble == .off }
    }

    @inline(__always) private func softClip(_ x: Float) -> Float {
        if x > 1 { return 1 }
        if x < -1 { return -1 }
        return x
    }
}
