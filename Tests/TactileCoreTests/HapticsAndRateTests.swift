import Testing
@testable import TactileCore

@Suite struct HapticsReportTests {
    // Source: tools/gen_vectors.py from the documented 0x32 facts (UNVERIFIED on
    // hardware): 141 bytes, sub-packet 0x11 (7 bytes, trailing counter), then 0x12
    // with 64 signed samples, CRC seed 0xA2. Samples are k-32 for k in 0..<64.
    let golden = hex("32 00 91 07 fe 00 00 00 00 ff 00 92 40 e0 e1 e2 e3 e4 e5 e6 e7 e8 e9 ea eb ec ed ee ef f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4c a1 e6 04")

    @Test func documentedFraming() {
        var b = HapticsReportBuilder()
        let r = b.build(samples: (0..<64).map { Int8($0 - 32) })
        #expect(r.count == 141)
        #expect(r == golden)
        #expect(CRC32.verify(r, prefix: .output))
    }

    @Test func sequenceAndCounterAdvance() {
        var b = HapticsReportBuilder()
        _ = b.build(samples: [])
        let r = b.build(samples: [])
        #expect(r[1] == 0x10)
        #expect(r[10] == 1)  // running counter at the end of the 0x11 sub-packet
        for _ in 0..<14 { _ = b.build(samples: []) }
        #expect(b.sequence == 0)
        #expect(b.counter == 16)
    }

    @Test func unsignedSamplesOption() {
        var f = HapticsFraming()
        f.signedSamples = false
        var b = HapticsReportBuilder(framing: f)
        let r = b.build(samples: [0, -128, 127])
        #expect(Array(r[13..<16]) == [0x80, 0x00, 0xFF])
        #expect(r[16] == 0x80)  // padding is silence, not zero, in offset-binary
    }

    @Test func periodConstants() {
        #expect(HapticsFormat.bytesPerReport == 64)
        #expect(abs(HapticsFormat.reportPeriodSeconds - 0.010_666_67) < 1e-6)
    }
}

@Suite struct RateLimiterTests {
    @Test func burstThenThrottle() {
        var r = RateLimiter(maxPerSecond: 100, burst: 2)  // 10 ms interval
        let a = r.tryAcquire(now: 0), b = r.tryAcquire(now: 0), c = r.tryAcquire(now: 1_000_000)
        #expect(a && b && !c)
        #expect(r.delayUntilAvailable(now: 1_000_000) > 0)
        let d = r.tryAcquire(now: 12_000_000)
        #expect(d)
    }

    @Test func sustainedRateIsCapped() {
        var r = RateLimiter(maxPerSecond: 250, burst: 1)
        var sent = 0
        for t in stride(from: UInt64(0), to: 1_000_000_000, by: 1_000_000) where r.tryAcquire(now: t) { sent += 1 }
        #expect(sent <= 251 && sent >= 249)
    }
}
