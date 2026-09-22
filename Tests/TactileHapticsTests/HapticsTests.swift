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
        _ = m.render(into: &out)  // producer stopped → play the remainder
        #expect(out[0] != 0)
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
