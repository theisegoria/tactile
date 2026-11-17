import Foundation
import Testing
import TactileCore
@testable import TactileHaptics

private func sine(_ f: Double, rate: Double = 48000, seconds: Double = 0.5, amp: Float = 0.5) -> [Float] {
    (0..<Int(rate * seconds)).map { amp * Float(sin(2 * .pi * f * Double($0) / rate)) }
}

private func level(_ x: [Float]) -> Float { rms(x[(x.count / 2)...]) }  // skip the transient

@Suite struct HapticFilterChainTests {
    @Test func passthroughIsIdentity() {
        var c = HapticFilterChain(settings: .passthrough, sampleRate: 48000)
        var x = sine(100)
        let original = x
        c.process(&x)
        #expect(x == original)
    }

    @Test func lowPassAttenuatesHighs() {
        let s = HapticFilterSettings(mode: .lowPass, highCutoff: 200, compressorThresholdDB: 0, compressorRatio: 1,
                                     makeupGainDB: 0, gateThresholdDB: -.infinity)
        var low = sine(60), high = sine(2000)
        var a = HapticFilterChain(settings: s, sampleRate: 48000), b = HapticFilterChain(settings: s, sampleRate: 48000)
        a.process(&low)
        b.process(&high)
        #expect(level(low) > 0.33)       // ~0.354 passes
        #expect(level(high) < 0.01)      // > 30 dB down two octaves+ above
    }

    @Test func bandPassRejectsBothEdges() {
        let s = HapticFilterSettings(mode: .bandPass, lowCutoff: 80, highCutoff: 250, compressorThresholdDB: 0,
                                     compressorRatio: 1, makeupGainDB: 0, gateThresholdDB: -.infinity)
        func run(_ f: Double) -> Float {
            var c = HapticFilterChain(settings: s, sampleRate: 48000)
            var x = sine(f)
            c.process(&x)
            return level(x)
        }
        #expect(run(150) > 0.3)
        #expect(run(10) < 0.03)
        #expect(run(3000) < 0.01)
    }

    @Test func gainAppliesInDecibels() {
        var c = HapticFilterChain(settings: HapticFilterSettings(mode: .none, inputGainDB: 6, compressorThresholdDB: 0,
                                                                 compressorRatio: 1, makeupGainDB: 0, gateThresholdDB: -.infinity),
                                  sampleRate: 48000)
        var x: [Float] = [0.25, -0.25]
        c.process(&x)
        #expect(abs(x[0] - 0.25 * pow(10, 6.0 / 20)) < 1e-4)
    }

    @Test func compressorReducesLoudSignals() {
        let s = HapticFilterSettings(mode: .none, compressorThresholdDB: -20, compressorRatio: 4,
                                     compressorAttack: 0.001, compressorRelease: 0.05, makeupGainDB: 0,
                                     gateThresholdDB: -.infinity)
        var c = HapticFilterChain(settings: s, sampleRate: 48000)
        var loud = sine(100, amp: 1)
        c.process(&loud)
        // Peak 0 dBFS, threshold -20, ratio 4 → about -15 dBFS peak (0.18).
        let peak = loud[(loud.count / 2)...].map(abs).max()!
        #expect(peak < 0.3 && peak > 0.12)
        #expect(c.gainReductionDB < -10)
        // Quiet signals below threshold pass unchanged.
        var q = HapticFilterChain(settings: s, sampleRate: 48000)
        var quiet = sine(100, amp: 0.05)
        let before = level(quiet)
        q.process(&quiet)
        #expect(abs(level(quiet) - before) < 0.002)
    }

    @Test func gateMutesNoiseFloor() {
        let s = HapticFilterSettings(mode: .none, compressorThresholdDB: 0, compressorRatio: 1, makeupGainDB: 0,
                                     gateThresholdDB: -40, gateRelease: 0.01)
        var c = HapticFilterChain(settings: s, sampleRate: 48000)
        var hiss = sine(100, amp: 0.001)   // -60 dBFS
        c.process(&hiss)
        #expect(level(hiss) < 1e-5)
        var c2 = HapticFilterChain(settings: s, sampleRate: 48000)
        var music = sine(100, amp: 0.5)
        c2.process(&music)
        #expect(level(music) > 0.3)
    }

    @Test func stereoIsLinked() {
        var c = HapticFilterChain(settings: .music, sampleRate: 48000)
        var l = sine(100, amp: 0.8)
        var r: [Float]? = sine(100, amp: 0.1)
        c.process(left: &l, right: &r)
        // One envelope: the ratio between channels is preserved.
        let ratio = level(l) / level(r!)
        #expect(abs(ratio - 8) < 0.2)
    }

    @Test func nonFiniteInputIsSilenced() {
        var c = HapticFilterChain(settings: .game, sampleRate: 48000)
        var x: [Float] = [.nan, .infinity, -.infinity, 0.5]
        c.process(&x)
        #expect(x.allSatisfy { $0.isFinite })
    }

    @Test func settingsAreCodableAndUpdatable() throws {
        let data = try JSONEncoder().encode(HapticFilterSettings.game)
        #expect(try JSONDecoder().decode(HapticFilterSettings.self, from: data) == .game)
        var c = HapticFilterChain(settings: .music, sampleRate: 48000)
        c.update(.passthrough)
        #expect(c.settings == .passthrough)
        var x = sine(100)
        let original = x
        c.process(&x)
        #expect(x == original)
    }

    @Test func pipelineFeedsMixerAtThreeKilohertz() {
        let mixer = HapticsMixer()
        let p = HapticAudioPipeline(mixer: mixer, inputRate: 48000, settings: .music)
        let l = sine(100, seconds: 0.2), r = sine(100, seconds: 0.2)
        let written = l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in p.process(channels: [lp, rp]) } }
        let flushed = p.flush()
        #expect(abs(written + flushed - 600) <= 2)   // 0.2 s at 3 kHz
        #expect(mixer.stream.availableToRead == (written + flushed) * 2)
        p.reconfigure(inputRate: 24000)
        #expect(p.chain.sampleRate == 24000)
        // Mono input is duplicated.
        let m = sine(100, rate: 24000, seconds: 0.1)
        let n = m.withUnsafeBufferPointer { p.process(channels: [$0]) }
        #expect(n > 0)
    }
}
