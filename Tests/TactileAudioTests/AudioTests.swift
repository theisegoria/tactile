import AVFAudio
import Foundation
import Synchronization
import Testing
import TactileCore
@testable import TactileAudio

func tone(frames: Int, channels: Int, rate: Double, hz: Double = 440, amp: Float = 0.5, offset: Int = 0) -> [Float] {
    var out = [Float](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let v = amp * Float(sin(2 * .pi * hz * Double(f + offset) / rate))
        for c in 0..<channels { out[f * channels + c] = v }
    }
    return out
}

func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot() }

@Suite struct OpusCodecTests {
    @Test(arguments: [OpusStreamFormat.speaker, .microphone])
    func roundTrip(format: OpusStreamFormat) throws {
        let enc = try OpusEncoder(format: format, bitRate: 64_000)
        let dec = try OpusDecoder(format: format)
        var decoded: [Float] = []
        var tocs = Set<UInt8>()
        for k in 0..<30 {
            let chunk = tone(frames: format.framesPerPacket, channels: format.channels, rate: format.sampleRate,
                             offset: k * format.framesPerPacket)
            for p in try enc.encode(interleaved: chunk) {
                #expect(p.count > 0 && p.count <= enc.maximumPacketSize)
                tocs.insert(p[0])
                decoded += try dec.decode(p)
            }
        }
        // One TOC per stream, decoding to the requested duration and channels.
        #expect(tocs.count == 1)
        let toc = try #require(tocs.first.map(OpusTOC.init))
        #expect(toc.frameDurationMicros == 10_000)
        #expect(toc.stereo == (format.channels == 2))
        let level = rms(decoded[(decoded.count / 3)...])
        #expect(abs(level - 0.5 / Float(2).squareRoot()) < 0.08)
    }

    @Test func speakerTOCMatchesLead() throws {
        // The lead says CELT fullband 48 kHz stereo 10 ms: config 30, stereo.
        let enc = try OpusEncoder(format: .speaker)
        let p = try #require(try enc.encode(interleaved: tone(frames: 480, channels: 2, rate: 48000)).first)
        let t = OpusTOC(p[0])
        #expect(t.mode == .celt && t.bandwidthHz == 48000 && t.stereo && t.config == 30)
    }

    @Test func flushPadsPartialFrame() throws {
        let enc = try OpusEncoder(format: .speaker)
        #expect(try enc.encode(interleaved: tone(frames: 100, channels: 2, rate: 48000)).isEmpty)
        #expect(try enc.flush().count == 1)
        #expect(try enc.flush().isEmpty)
    }

    @Test func nonFiniteInputIsSilenced() throws {
        let enc = try OpusEncoder(format: .microphone)
        let packets = try enc.encode(interleaved: [Float](repeating: .nan, count: 240))
        #expect(packets.count == 1)
    }

    @Test func garbageDoesNotCrashDecoder() throws {
        let dec = try OpusDecoder(format: .microphone)
        _ = try? dec.decode([0xFF, 0xFF, 0xFF])
        #expect(try dec.decode([]).isEmpty)
    }

    @Test func unsupportedFormat() {
        #expect(throws: OpusCodecError.self) { try OpusEncoder(format: OpusStreamFormat(sampleRate: 48000, channels: 6)) }
    }
}

@Suite struct SpeakerStreamTests {
    @Test func pacesValidReports() async throws {
        let sent = Mutex<[[UInt8]]>([])
        let framing = SpeakerAudioFraming(reportLength: 200)
        let stream = SpeakerStream(framing: framing, bitRate: 64_000) { r in sent.withLock { $0.append(r) } }
        let chunks = (0..<20).map { tone(frames: 480, channels: 2, rate: 48000, offset: $0 * 480) }
        let clock = ContinuousClock()
        let t0 = clock.now
        let stats = try await stream.play(chunks: chunks)
        let elapsed = clock.now - t0
        let reports = sent.withLock { $0 }
        #expect(stats.packetsSent == reports.count && reports.count >= 20)
        #expect(stats.packetsDroppedOversize == 0 && stats.sendFailures == 0)
        #expect(reports.allSatisfy { $0.count == 200 && $0[0] == 0x36 && CRC32.verify($0, prefix: .output) })
        // Packet length prefix and TOC in place.
        #expect(reports.allSatisfy { Int($0[2]) > 0 && OpusTOC($0[3]).config == 30 })
        // Real-time pacing: ≈10 ms per packet.
        #expect(elapsed >= .milliseconds(180))
    }

    @Test func oversizePacketsAreDroppedNotTruncated() async throws {
        let sent = Mutex(0)
        let stream = SpeakerStream(framing: SpeakerAudioFraming(reportLength: 20), bitRate: 256_000) { _ in sent.withLock { $0 += 1 } }
        let stats = try await stream.play(chunks: (0..<5).map { tone(frames: 480, channels: 2, rate: 48000, offset: $0 * 480) })
        #expect(stats.packetsDroppedOversize > 0)
        #expect(sent.withLock { $0 } == stats.packetsSent)
    }

    @Test func playsWavFileWithChannelMapping() async throws {
        // Mono 44.1 kHz file → 48 kHz stereo packets.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tactile-speaker-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let b = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4410))
            b.frameLength = 4410
            let s = tone(frames: 4410, channels: 1, rate: 44100)
            for i in 0..<4410 { b.floatChannelData![0][i] = s[i] }
            try f.write(from: b)
        }
        let sent = Mutex(0)
        let stream = SpeakerStream(framing: SpeakerAudioFraming(reportLength: 200), bitRate: 64_000) { r in
            #expect(OpusTOC(r[3]).stereo)
            sent.withLock { $0 += 1 }
        }
        let stats = try await stream.play(url: url)
        #expect(stats.packetsSent >= 10 && stats.packetsSent <= 12)  // 100 ms
    }
}

@Suite struct MicUplinkTests {
    /// Synthetic uplink with the layout the scanner is meant to discover:
    /// [0x35, counter, 0, length, opus…, pad…, crc×4].
    func reports(_ n: Int) throws -> [[UInt8]] {
        let enc = try OpusEncoder(format: .microphone, bitRate: 32_000)
        var out: [[UInt8]] = []
        for k in 0..<n {
            for p in try enc.encode(interleaved: tone(frames: 240, channels: 1, rate: 24000, offset: k * 240)) {
                var r = [UInt8](repeating: 0, count: 4 + 200 + 4)
                r[0] = 0x35
                r[1] = UInt8(k & 0xFF)
                r[3] = UInt8(p.count)
                r.replaceSubrange(4..<(4 + p.count), with: p)
                CRC32.seal(&r, prefix: .input)
                out.append(r)
            }
        }
        return out
    }

    @Test func scannerThenDecoderRecoverAudio() throws {
        let reps = try reports(60)
        var scanner = UplinkScanner()
        reps.forEach { scanner.add($0) }
        let best = try #require(scanner.candidates().first)
        #expect(best.reportID == 0x35 && best.tocOffset == 4 && best.lengthOffset == 3)
        let dec = try MicUplinkDecoder(extractor: UplinkExtractor(best))
        var pcm: [Float] = []
        for r in reps { pcm += dec.process(r) ?? [] }
        #expect(dec.stats.decodeErrors == 0 && dec.stats.packetsDecoded == reps.count)
        #expect(abs(rms(pcm[(pcm.count / 3)...]) - 0.5 / Float(2).squareRoot()) < 0.08)
        #expect(dec.process([0x31, 1, 2]) == nil)
    }

    @Test func recordsWav() async throws {
        let reps = try reports(20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tactile-mic-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let dec = try MicUplinkDecoder(extractor: UplinkExtractor(reportID: 0x35, tocOffset: 4, lengthOffset: 3))
        let stream = AsyncStream<[UInt8]> { c in reps.forEach { c.yield($0) }; c.finish() }
        let stats = try await dec.record(reports: stream, to: url, duration: .seconds(5))
        #expect(stats.packetsDecoded == reps.count)
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.sampleRate == 24000)
        #expect(abs(Int(f.length) - 20 * 240) <= 480)
    }
}
