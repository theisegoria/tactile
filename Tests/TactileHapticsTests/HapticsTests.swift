import Foundation
import Synchronization
import Testing
import TactileCore
@testable import TactileHaptics

func rms(_ x: ArraySlice<Float>) -> Float {
    (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
}

@Suite struct ResamplerTests {
    func tone(_ f: Double, rate: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amp * Float(sin(2 * .pi * f * Double($0) / rate)) }
    }

    @Test func outputCountMatchesRatio() {
        var r = StreamingResampler(inputRate: 48000)
        var out: [Float] = []
        r.process(tone(100, rate: 48000, seconds: 1), into: &out)
        // 3000 per second minus the filter look-ahead.
        #expect(abs(out.count - 3000) < Int(r.latencyOutputSamples) + 3)
    }

    @Test func passbandPreserved() {
        var r = StreamingResampler(inputRate: 48000)
        var out: [Float] = []
        r.process(tone(150, rate: 48000, seconds: 1), into: &out)
        let level = rms(out[200...])
        #expect(abs(level - Float(0.5) / Float(2).squareRoot()) < 0.02)
    }

    @Test func aliasingRejected() {
        // 4 kHz would alias to 1 kHz at 3 kHz output; it must be filtered away.
        var r = StreamingResampler(inputRate: 48000)
        var out: [Float] = []
        r.process(tone(4000, rate: 48000, seconds: 1), into: &out)
        #expect(rms(out[200...]) < 0.01)
    }

    @Test func upsamplingFromLowRate() {
        var r = StreamingResampler(inputRate: 1000)
        var out: [Float] = []
        r.process(tone(50, rate: 1000, seconds: 1), into: &out)
        #expect(out.count > 2900)
        #expect(abs(rms(out[300...]) - Float(0.5) / Float(2).squareRoot()) < 0.03)
    }
}

@Suite struct QuantizerTests {
    @Test func rangeAndSilence() {
        var q = Quantizer8()
        #expect(q.quantize(0) == 0)  // silence stays exactly silent
        #expect(q.quantize(10) == 127)
        #expect(q.quantize(-10) == -127)
        #expect(q.quantize(.nan) == 0)  // Int8(NaN) would trap
        #expect(q.quantize(.infinity) == 127)
        #expect(q.quantize(-.infinity) == -127)
    }

    @Test func ditherIsUnbiased() {
        var q = Quantizer8()
        let x: Float = 0.3 / 127  // 0.3 LSB
        let mean = (0..<20000).reduce(0.0) { acc, _ in acc + Double(q.quantize(x)) } / 20000
        #expect(abs(mean - 0.3) < 0.05)
        var plain = Quantizer8(dither: false)
        #expect(plain.quantize(x) == 0)
    }
}

@Suite struct RingBufferTests {
    @Test func requestClearDropsOnlyWhatWasWrittenBefore() {
        let rb = SPSCRingBuffer(capacity: 16)
        rb.write([1, 2, 3, 4, 5])
        rb.requestClear()
        rb.write([6, 7])
        #expect(rb.availableToRead == 7)  // takes effect on the consumer side
        #expect(rb.applyPendingClear())
        #expect(!rb.applyPendingClear())
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { out.deallocate() }
        #expect(rb.read(into: out, count: 16) == 2)
        #expect(out[0] == 6 && out[1] == 7)
        // A request covering already-consumed data is a no-op.
        rb.write([8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])  // wraps
        _ = rb.read(into: out, count: 4)
        rb.requestClear()
        rb.write([20])
        #expect(rb.applyPendingClear())
        #expect(rb.read(into: out, count: 16) == 1 && out[0] == 20)
    }

    @Test func wrapAround() {
        let rb = SPSCRingBuffer(capacity: 8)
        var out = [Float](repeating: 0, count: 8)
        #expect(rb.write([1, 2, 3, 4, 5, 6]) == 6)
        #expect(out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: 4) } == 4)
        #expect(rb.write([7, 8, 9, 10, 11, 12]) == 6)
        #expect(rb.write([13]) == 0)  // full
        #expect(out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: 8) } == 8)
        #expect(out == [5, 6, 7, 8, 9, 10, 11, 12])
    }

    @Test func concurrentProducerConsumer() async {
        let rb = SPSCRingBuffer(capacity: 256)
        let total = 100_000
        let producer = Task.detached {
            var next: Float = 0
            while next < Float(total) {
                let chunk = (0..<37).map { next + Float($0) }.filter { $0 < Float(total) }
                let n = rb.write(chunk)
                next += Float(n)
                if n == 0 { await Task.yield() }
            }
        }
        let consumer = Task.detached { () -> Bool in
            var expected: Float = 0
            var buf = [Float](repeating: 0, count: 64)
            while expected < Float(total) {
                let n = buf.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: 64) }
                for i in 0..<n where buf[i] != expected + Float(i) { return false }
                expected += Float(n)
                if n == 0 { await Task.yield() }
            }
            return true
        }
        await producer.value
        #expect(await consumer.value)
    }
}

@Suite struct ResamplerRobustnessTests {
    @Test func invalidRatesAreClampedNotTrapped() {
        for rate in [Double.infinity, -.infinity, .nan, 0, -48000, 1e-300, 1e30] {
            var r = StreamingResampler(inputRate: rate)
            #expect(StreamingResampler.supportedRates.contains(r.inputRate))
            var out: [Float] = []
            r.process([Float](repeating: 0.25, count: 64), into: &out)  // must terminate
            #expect(out.allSatisfy { $0.isFinite })
        }
        #expect(!StreamingResampler.isSupported(rate: .infinity))
        #expect(!StreamingResampler.isSupported(rate: 0))
        #expect(StreamingResampler.isSupported(rate: 48000))
    }

    @Test func nonFiniteInputDoesNotPoisonHistory() {
        var r = StreamingResampler(inputRate: 48000)
        var input = [Float](repeating: 0.25, count: 4800)
        input[100] = .nan; input[200] = .infinity; input[300] = -.infinity
        var out: [Float] = []
        r.process(input, into: &out)
        #expect(!out.isEmpty && out.allSatisfy { $0.isFinite })
    }

    @Test func flushEmitsTheLookAheadTail() {
        var r = StreamingResampler(inputRate: 48000)
        var out: [Float] = []
        r.process([Float](repeating: 0.5, count: 4800), into: &out)  // 100 ms → 300 outputs
        let beforeFlush = out.count
        #expect(beforeFlush < 300)
        r.flush(into: &out)
        #expect(out.count == 300)
        #expect(abs(out[beforeFlush] - 0.5) < 0.1)  // real signal, not silence
        // Reset: the next stream starts from scratch.
        var again: [Float] = []
        r.process([Float](repeating: 0.5, count: 4800), into: &again)
        #expect(again.count == beforeFlush)
    }

    @Test func pcmInputFlushWritesTail() {
        let m = HapticsMixer()
        let input = PCMInput(mixer: m, inputRate: 48000)
        let fed = input.feed(interleaved: [Float](repeating: 0.5, count: 960 * 2), channelCount: 2)  // 20 ms
        let tail = input.flush()
        #expect(fed + tail == 60)
        #expect(m.stream.availableToRead == 120)
    }
}

@Suite struct MixerTests {
    @Test func underrunRendersSilence() {
        let m = HapticsMixer(streamPrefillFrames: 0)
        m.stream.write([Float](repeating: 0.5, count: 20))  // 10 frames only
        var out: [Int8] = []
        let under = m.render(into: &out)
        #expect(under == 22)
        #expect(out.count == 64)
        #expect(out[0] != 0)
        #expect(out[20...].allSatisfy { $0 == 0 })  // never stale data
        // Next render: nothing buffered → full silence (re-buffering, not an underrun).
        #expect(m.render(into: &out) == 0)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func prefillBuffersBeforePlaying() {
        let m = HapticsMixer(streamPrefillFrames: 64)
        var out: [Int8] = []
        m.stream.write([Float](repeating: 0.5, count: 100))  // 50 frames < prefill
        #expect(m.render(into: &out) == 0)
        // Producer still adding: keep buffering.
        m.stream.write([Float](repeating: 0.5, count: 40))  // 70 frames ≥ prefill
        #expect(m.render(into: &out) == 0)
        #expect(out.allSatisfy { $0 != 0 })
        #expect(m.stream.availableToRead == 76)
    }

    @Test func shortClipBelowPrefillStillPlays() {
        let m = HapticsMixer(streamPrefillFrames: 64)
        var out: [Int8] = []
        m.stream.write([Float](repeating: 0.5, count: 20))
        _ = m.render(into: &out)  // buffering
        #expect(out.allSatisfy { $0 == 0 })
        // Level unchanged for stallTicksBeforePlaying periods → producer stopped.
        for _ in 1..<HapticsMixer.stallTicksBeforePlaying {
            _ = m.render(into: &out)
            #expect(out.allSatisfy { $0 == 0 })
        }
        _ = m.render(into: &out)  // play the remainder
        #expect(out[0] != 0)
    }

    @Test func finishStreamPlaysShortClipImmediately() {
        let m = HapticsMixer(streamPrefillFrames: 64)
        var out: [Int8] = []
        m.stream.write([Float](repeating: 0.5, count: 20))
        m.finishStream()
        _ = m.render(into: &out)
        #expect(out[0] != 0)
    }

    @Test func singleProducerGapDoesNotBypassPrefill() {
        // A live producer delivering ~35 frames per callback, with one pump
        // tick that sees no new data, must still fill the 64-frame prefill.
        let m = HapticsMixer(streamPrefillFrames: 64)
        var out: [Int8] = []
        m.stream.write([Float](repeating: 0.5, count: 70))  // 35 frames
        _ = m.render(into: &out)
        _ = m.render(into: &out)  // gap tick: level unchanged
        #expect(out.allSatisfy { $0 == 0 })
        #expect(m.stream.availableToRead == 70)
        m.stream.write([Float](repeating: 0.5, count: 70))  // 70 frames ≥ prefill
        _ = m.render(into: &out)
        #expect(out.allSatisfy { $0 != 0 })
    }

    @Test func nonFiniteSamplesRenderAsSilenceInsteadOfTrapping() {
        let m = HapticsMixer(streamPrefillFrames: 0)
        var samples = [Float](repeating: 0, count: 64)
        samples[0] = .nan; samples[1] = .nan
        samples[2] = .infinity; samples[3] = -.infinity
        m.stream.write(samples)
        var out: [Int8] = []
        _ = m.render(into: &out)
        #expect(out[0] == 0 && out[1] == 0)
        #expect(out[2] == 127 && out[3] == -127)
        m.play(.tone(intensity: .nan, frequency: 100, duration: 0.1))
        _ = m.render(into: &out)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func stopAllFlushesQueuedStreamOnNextBlockOnly() {
        let m = HapticsMixer(streamPrefillFrames: 0)
        m.stream.write([Float](repeating: 0.5, count: 200))
        m.play(.tone(intensity: 1, frequency: 100, duration: 10))
        m.setRumble(Rumble(left: 255, right: 255))
        m.stopAll()
        // Audio written after the stop request is kept.
        m.stream.write([Float](repeating: -0.5, count: 64))
        var out: [Int8] = []
        _ = m.render(into: &out)
        #expect(out.allSatisfy { $0 < 0 })
        #expect(m.stream.availableToRead == 0)
        #expect(m.isIdle)
    }

    @Test func stopAllDuringRenderDoesNotResurrectVoices() async {
        // Hammer render (the pump side) and stopAll concurrently; after the
        // last stopAll with no render in flight, nothing may still be playing.
        let m = HapticsMixer()
        let done = Atomic<Bool>(false)
        let renderer = Task.detached {
            var out: [Int8] = []
            while !done.load(ordering: .acquiring) { _ = m.render(into: &out) }
        }
        for _ in 0..<2000 {
            m.play(.tone(intensity: 1, frequency: 100, duration: 10))
            m.stopAll()
        }
        done.store(true, ordering: .releasing)
        await renderer.value
        var out: [Int8] = []
        _ = m.render(into: &out)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(m.isIdle)
    }

    @Test func parametricEffectsPlayAndFinish() {
        let m = HapticsMixer()
        m.play(.click(), side: .left)
        var out: [Int8] = []
        _ = m.render(into: &out)
        let left = stride(from: 0, to: 64, by: 2).map { out[$0] }
        let right = stride(from: 1, to: 64, by: 2).map { out[$0] }
        #expect(left.contains { $0 != 0 })
        #expect(right.allSatisfy { $0 == 0 })
        #expect(!m.isIdle)  // a 12 ms click (36 samples) spans two 32-frame blocks
        _ = m.render(into: &out)
        _ = m.render(into: &out)
        #expect(m.isIdle)
    }

    @Test func rumbleEmulation() {
        let m = HapticsMixer()
        m.setRumble(Rumble(left: 255, right: 0))
        #expect(!m.isIdle)
        var out: [Int8] = []
        for _ in 0..<4 { _ = m.render(into: &out) }
        #expect(out.contains { $0 != 0 })
        m.setRumble(.off)
        #expect(m.isIdle)
    }

    @Test func effectDurations() {
        #expect(HapticEffect.impact().duration > HapticEffect.click().duration)
        #expect(HapticEffect.texture(duration: 2).duration == 2)
    }

    @Test func nonFiniteAndHugeDurationsDoNotTrap() {
        for d in [Double.infinity, -.infinity, .nan, 1e30, -5] {
            let v = Voice(effect: .tone(intensity: 1, frequency: 100, duration: d), side: .both, sampleRate: 3000, seed: 1)
            #expect(v.length >= 1 && v.length <= Int(HapticEffect.maximumDuration * 3000))
        }
        var v = Voice(effect: .texture(intensity: 1, grainRate: .nan, duration: 0.1), side: .both, sampleRate: 3000, seed: 1)
        for _ in 0..<300 { #expect(v.next().isFinite) }
    }

    @Test func textureGrainsAllStartAtFullLevel() {
        // Every grain has the same envelope regardless of its jittered spacing.
        var v = Voice(effect: .texture(intensity: 1, grainRate: 60, duration: 2), side: .both, sampleRate: 3000, seed: 7)
        var peaks: [Float] = []
        var current: Float = 0
        var lastStart = 0
        for _ in 0..<6000 {
            let x = abs(v.next())
            if v.grainStart != lastStart {
                peaks.append(current); current = 0; lastStart = v.grainStart
            }
            current = max(current, x)
        }
        let body = peaks.dropFirst().dropLast()
        #expect(body.count > 50)
        let lo = body.min() ?? 0, hi = body.max() ?? 0
        #expect(lo > 0.9 * hi)
    }
}

final class CountingSink: HapticsReportSink, @unchecked Sendable {
    let reports = Mutex<[[UInt8]]>([])
    func submit(_ report: [UInt8], completion: @escaping @Sendable (Bool) -> Void) {
        reports.withLock { $0.append(report) }
        completion(true)
    }
}

@Suite struct PumpTests {
    @Test func cadenceAndValidReports() async throws {
        let mixer = HapticsMixer()
        let sink = CountingSink()
        let pump = HapticsPump(mixer: mixer, sink: sink, sendWhileIdle: true)
        pump.start()
        try await Task.sleep(for: .milliseconds(320))
        pump.stop()
        try await Task.sleep(for: .milliseconds(30))
        let reports = sink.reports.withLock { $0 }
        // 320 ms / 10.667 ms ≈ 30 reports; allow for CI scheduling slack.
        #expect(reports.count >= 22 && reports.count <= 33)
        #expect(reports.allSatisfy { $0.count == 141 && CRC32.verify($0, prefix: .output) })
        let m = pump.metrics()
        #expect(abs(m.tickIntervalMeanUs - 10_666.7) < 1_500)
        #expect(m.reportsSent == reports.count)
    }

    @Test func stopJoinsThreadAndRestartDoesNotDoublePump() async throws {
        let sink = CountingSink()
        let pump = HapticsPump(mixer: HapticsMixer(), sink: sink, sendWhileIdle: true)
        pump.start()
        try await Task.sleep(for: .milliseconds(30))
        for _ in 0..<20 { pump.stop(); pump.start() }  // back to back, within one period
        let before = sink.reports.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(320))
        pump.stop()
        let after = sink.reports.withLock { $0.count }
        // One pump: ≈30 reports in 320 ms. Two surviving threads would give ≈60.
        #expect(after - before <= 36)
        try await Task.sleep(for: .milliseconds(40))
        #expect(sink.reports.withLock { $0.count } == after)  // nothing after stop() returned
        #expect(!pump.isRunning)
    }

    @Test func metricsRightAfterStartDoNotTrap() async throws {
        let pump = HapticsPump(mixer: HapticsMixer(), sink: CountingSink(), sendWhileIdle: true)
        for _ in 0..<3 {
            pump.start()
            let end = ContinuousClock.now + .milliseconds(25)
            while ContinuousClock.now < end {
                let m = pump.metrics()
                #expect(m.pumpCPUPercent >= 0 && m.pumpCPUPercent.isFinite)
            }
            pump.stop()
        }
    }

    @Test func idlePumpStopsSending() async throws {
        let sink = CountingSink()
        let pump = HapticsPump(mixer: HapticsMixer(), sink: sink, sendWhileIdle: false)
        pump.start()
        try await Task.sleep(for: .milliseconds(250))
        pump.stop()
        // Sends a short tail of silence, then goes quiet.
        #expect(sink.reports.withLock { $0.count } <= 10)
    }
}
