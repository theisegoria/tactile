// Audio → haptics conditioning: filter (low-pass or band-pass), gain,
// compressor and noise gate, run on PCM before it is resampled to 3 kHz.
// Voice coils respond best roughly between 50 and 400 Hz, so music and game
// audio feel better band-limited and compressed than played raw.

import Foundation

/// Settings for `HapticFilterChain`. Codable so apps can store them.
public struct HapticFilterSettings: Sendable, Hashable, Codable {
    public enum FilterMode: String, Sendable, Hashable, Codable, CaseIterable {
        /// No filtering (the resampler still removes everything above 1.5 kHz).
        case none
        /// Second-order Butterworth low-pass at `highCutoff`.
        case lowPass
        /// High-pass at `lowCutoff` followed by low-pass at `highCutoff`.
        case bandPass
    }

    public var mode: FilterMode
    /// Low edge of the band-pass, Hz.
    public var lowCutoff: Double
    /// Low-pass cutoff (or the band-pass high edge), Hz.
    public var highCutoff: Double
    /// Gain before the compressor, dB.
    public var inputGainDB: Float
    /// Compressor threshold, dBFS. 0 with ratio 1 disables it.
    public var compressorThresholdDB: Float
    /// Compression ratio (≥ 1; 1 = off).
    public var compressorRatio: Float
    /// Seconds.
    public var compressorAttack: Double
    /// Seconds.
    public var compressorRelease: Double
    /// Gain after the compressor, dB.
    public var makeupGainDB: Float
    /// Signals whose envelope stays below this (dBFS) are muted. −∞ (or ≤ −120) disables the gate.
    public var gateThresholdDB: Float
    /// Gate open/close smoothing, seconds.
    public var gateRelease: Double

    public init(mode: FilterMode = .bandPass, lowCutoff: Double = 30, highCutoff: Double = 250,
                inputGainDB: Float = 0, compressorThresholdDB: Float = -24, compressorRatio: Float = 4,
                compressorAttack: Double = 0.005, compressorRelease: Double = 0.12, makeupGainDB: Float = 9,
                gateThresholdDB: Float = -55, gateRelease: Double = 0.05) {
        self.mode = mode
        self.lowCutoff = lowCutoff
        self.highCutoff = highCutoff
        self.inputGainDB = inputGainDB
        self.compressorThresholdDB = compressorThresholdDB
        self.compressorRatio = compressorRatio
        self.compressorAttack = compressorAttack
        self.compressorRelease = compressorRelease
        self.makeupGainDB = makeupGainDB
        self.gateThresholdDB = gateThresholdDB
        self.gateRelease = gateRelease
    }

    /// Everything off: unity gain, no filter, no compressor, no gate.
    public static let passthrough = HapticFilterSettings(mode: .none, inputGainDB: 0, compressorThresholdDB: 0,
                                                         compressorRatio: 1, makeupGainDB: 0, gateThresholdDB: -.infinity)
    /// Music: bass band, firm compression.
    public static let music = HapticFilterSettings()
    /// Game audio: wider band, gentler compression, tighter gate.
    public static let game = HapticFilterSettings(mode: .bandPass, lowCutoff: 40, highCutoff: 400,
                                                  compressorThresholdDB: -20, compressorRatio: 3, makeupGainDB: 6,
                                                  gateThresholdDB: -45)
}

/// RBJ-cookbook biquad, transposed direct form II.
struct Biquad: Sendable {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    enum Kind { case lowPass, highPass }

    init(_ kind: Kind, cutoff: Double, sampleRate: Double, q: Double = 0.5.squareRoot()) {
        let nyquist = sampleRate / 2
        guard sampleRate > 0, cutoff.isFinite, cutoff > 0, cutoff < nyquist * 0.98 else {
            // Out of range: low-pass passes everything, high-pass too (cutoff ≥ Nyquist
            // means the request cannot be honoured; leave the signal alone).
            return
        }
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        switch kind {
        case .lowPass:
            b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0); b2 = b0
        case .highPass:
            b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
        }
        a1 = Float(-2 * c / a0)
        a2 = Float((1 - alpha) / a0)
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        if !y.isFinite { z1 = 0; z2 = 0; return 0 }
        return y
    }
}

/// The filter → gain → compressor → gate chain for one stream of stereo (or
/// mono) PCM. Channels are linked: one envelope drives both, so the stereo
/// image is kept. Not thread-safe; use one instance per producer.
public struct HapticFilterChain: Sendable {
    public private(set) var settings: HapticFilterSettings
    public let sampleRate: Double
    private var filters: [[Biquad]] = [[], []]
    private var envelope: Float = 0
    private var gateGain: Float = 1
    private var attackCoef: Float = 0
    private var releaseCoef: Float = 0
    private var gateCoef: Float = 0
    private var inputGain: Float = 1
    private var makeup: Float = 1
    /// Envelope (linear peak) after the last processed block, for metering.
    public private(set) var lastEnvelope: Float = 0
    /// Current gain reduction in dB (≤ 0), for metering.
    public private(set) var gainReductionDB: Float = 0

    public init(settings: HapticFilterSettings = .music, sampleRate: Double) {
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        self.settings = settings
        configure(settings)
    }

    /// Replaces the settings. Filter state restarts when the filter changes.
    public mutating func update(_ new: HapticFilterSettings) {
        let filterChanged = new.mode != settings.mode || new.lowCutoff != settings.lowCutoff || new.highCutoff != settings.highCutoff
        settings = new
        configure(new, rebuildFilters: filterChanged)
    }

    private static func dbToLinear(_ db: Float) -> Float { db.isFinite ? pow(10, db / 20) : (db > 0 ? 1 : 0) }

    private func coefficient(_ seconds: Double) -> Float {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Float(exp(-1 / (seconds * sampleRate)))
    }

    private mutating func configure(_ s: HapticFilterSettings, rebuildFilters: Bool = true) {
        inputGain = Self.dbToLinear(min(s.inputGainDB, 40))
        makeup = Self.dbToLinear(min(s.makeupGainDB, 40))
        attackCoef = coefficient(s.compressorAttack)
        releaseCoef = coefficient(s.compressorRelease)
        gateCoef = coefficient(s.gateRelease)
        guard rebuildFilters else { return }
        func chain() -> [Biquad] {
            switch s.mode {
            case .none: []
            case .lowPass: [Biquad(.lowPass, cutoff: s.highCutoff, sampleRate: sampleRate)]
            case .bandPass: [Biquad(.highPass, cutoff: s.lowCutoff, sampleRate: sampleRate),
                             Biquad(.lowPass, cutoff: s.highCutoff, sampleRate: sampleRate)]
            }
        }
        filters = [chain(), chain()]
    }

    /// Processes planar channels in place (1 or 2; extra channels are left alone).
    public mutating func process(left: inout [Float], right: inout [Float]?) {
        let n = right.map { min(left.count, $0.count) } ?? left.count
        let ratio = max(1, settings.compressorRatio.isFinite ? settings.compressorRatio : 1)
        let threshold = settings.compressorThresholdDB
        let gateOn = settings.gateThresholdDB.isFinite && settings.gateThresholdDB > -120
        let gateLevel = Self.dbToLinear(settings.gateThresholdDB)
        var reduction: Float = 0
        for i in 0..<n {
            var l = left[i].isFinite ? left[i] * inputGain : 0
            var r = right.map { $0[i].isFinite ? $0[i] * inputGain : 0 } ?? l
            for k in filters[0].indices { l = filters[0][k].process(l) }
            if right != nil { for k in filters[1].indices { r = filters[1][k].process(r) } } else { r = l }
            // Peak envelope, linked across channels.
            let peak = max(abs(l), abs(r))
            let coef = peak > envelope ? attackCoef : releaseCoef
            envelope = coef * envelope + (1 - coef) * peak
            var g: Float = 1
            if ratio > 1, envelope > 0 {
                let levelDB = 20 * log10(envelope)
                if levelDB > threshold {
                    let outDB = threshold + (levelDB - threshold) / ratio
                    reduction = outDB - levelDB
                    g = pow(10, reduction / 20)
                } else {
                    reduction = 0
                }
            }
            if gateOn {
                let target: Float = envelope >= gateLevel ? 1 : 0
                gateGain = gateCoef * gateGain + (1 - gateCoef) * target
            } else {
                gateGain = 1
            }
            let total = g * makeup * gateGain
            left[i] = l * total
            if right != nil { right![i] = r * total }
        }
        lastEnvelope = envelope
        gainReductionDB = reduction
    }

    /// Mono convenience.
    public mutating func process(_ samples: inout [Float]) {
        var none: [Float]? = nil
        process(left: &samples, right: &none)
    }
}

/// Filter chain + resampler feeding a mixer's stream: the PCM path used by
/// `SystemAudioHapticsSource`, usable with any float PCM producer.
/// Not thread-safe: call from one producer thread.
public final class HapticAudioPipeline: @unchecked Sendable {
    public let input: PCMInput
    public private(set) var chain: HapticFilterChain
    private var l: [Float] = []
    private var r: [Float] = []

    public init(mixer: HapticsMixer, inputRate: Double, settings: HapticFilterSettings = .music) {
        input = PCMInput(mixer: mixer, inputRate: inputRate)
        chain = HapticFilterChain(settings: settings, sampleRate: inputRate)
    }

    public func update(_ settings: HapticFilterSettings) { chain.update(settings) }

    /// Rebuilds the chain for a new input rate (keeps the settings).
    public func reconfigure(inputRate: Double) {
        guard inputRate != chain.sampleRate else { return }
        input.reconfigure(inputRate: inputRate)
        chain = HapticFilterChain(settings: chain.settings, sampleRate: inputRate)
    }

    /// Processes planar channels (1 = mono, 2+ = first two) and queues the
    /// result. Returns the number of 3 kHz frames written.
    @discardableResult
    public func process(channels: [UnsafeBufferPointer<Float>]) -> Int {
        guard let first = channels.first else { return 0 }
        l.removeAll(keepingCapacity: true)
        l.append(contentsOf: first)
        if channels.count > 1 {
            var right: [Float]? = Array(channels[1])
            chain.process(left: &l, right: &right)
            r = right ?? []
        } else {
            chain.process(&l)
            r = l
        }
        return l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in input.feed(channels: [lp, rp]) } }
    }

    /// Writes the resampler tail (end of stream).
    @discardableResult
    public func flush() -> Int { input.flush() }
}
