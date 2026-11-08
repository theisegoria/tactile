import Foundation
import Synchronization
import Testing
import TactileCore
@testable import TactileAudio

/// Collects the reports a pump sends; nothing reaches a device.
private final class Sink: Sendable {
    let reports = Mutex<[[UInt8]]>([])
    var count: Int { reports.withLock { $0.count } }
    var all: [[UInt8]] { reports.withLock { $0 } }
    func send(_ r: [UInt8]) { reports.withLock { $0.append(r) } }
}

private func waitUntil(_ timeout: Duration = .seconds(3), _ predicate: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

@Suite(.serialized) struct SpeakerPumpTests {
    fileprivate func pump(_ sink: Sink, length: Int = 160, idleMs: Int = 30, queueMs: Int = 100) throws -> SpeakerPump {
        var o = SpeakerPumpOptions()
        o.idleMilliseconds = idleMs
        o.queueMilliseconds = queueMs
        return try SpeakerPump(framing: SpeakerAudioFraming(reportLength: length), options: o) { r in sink.send(r) }
    }

    @Test func opusPacketsGoOutByteExactInOrder() async throws {
        let sink = Sink()
        let p = try pump(sink)
        #expect(p.write(opusPacket: [0xF4, 1, 2, 3, 4]))
        #expect(p.write(opusPacket: [0xF4, 0xAA, 0x55]))
        #expect(await waitUntil { sink.count >= 2 })
        let r = sink.all
        // Same layout as tools/gen_vectors.py spk_seq0/spk_seq1, at length 160.
        #expect(r[0].count == 160 && r[0][0] == 0x36 && r[0][1] == 0x00 && r[0][2] == 5)
        #expect(Array(r[0][3..<8]) == [0xF4, 1, 2, 3, 4])
        #expect(r[0][8..<156].allSatisfy { $0 == 0 })
        #expect(r[1][1] == 0x10 && r[1][2] == 3 && Array(r[1][3..<6]) == [0xF4, 0xAA, 0x55])
        #expect(r.allSatisfy { CRC32.verify($0, prefix: .output) })
        await p.close()
    }

    @Test func underrunPadsWithSilenceThenTheStreamEnds() async throws {
        let sink = Sink()
        let p = try pump(sink, idleMs: 30)
        #expect(p.write(opusPacket: [0xF4, 7]))
        #expect(await waitUntil { !p.stats.streaming && sink.count > 1 })
        let s = p.stats
        #expect(s.packetsSent == 4)          // 1 queued + 3 silence (30 ms idle)
        #expect(s.silencePackets == 3)
        // Silence is encoded by the system Opus encoder: CELT FB 10 ms stereo TOC.
        #expect(sink.all.dropFirst().allSatisfy { $0[3] == 0xF4 })
        // The next write restarts it and the 4-bit sequence carries on.
        #expect(p.write(opusPacket: [0xF4, 8]))
        #expect(await waitUntil { sink.count == 5 })
        #expect(sink.all[4][1] == 0x40)
        await p.close()
    }

    @Test func pcmIsEncodedToOpusCELT() async throws {
        let sink = Sink()
        let p = try pump(sink, length: 400)
        let mono = (0..<960).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.25 }
        let accepted = mono.withUnsafeBufferPointer { p.write(interleaved: $0, channels: 1) }
        #expect(accepted == 960)
        #expect(await waitUntil { sink.count >= 2 })
        for r in sink.all.prefix(2) {
            let n = Int(r[2])
            #expect(n > 0 && n <= p.framing.maxPacketBytes)
            #expect(r[3] == 0xF4)
            #expect(CRC32.verify(r, prefix: .output))
        }
        await p.close()
    }

    @Test func boundedQueueDropsAndOversizeIsRefused() async throws {
        let sink = Sink()
        let p = try pump(sink, length: 20, queueMs: 20)        // two 10 ms packets
        #expect(p.framing.maxPacketBytes == 20 - 3 - 4)
        #expect(!p.write(opusPacket: [UInt8](repeating: 0xF4, count: 14)))
        #expect(p.stats.packetsDroppedOversize == 1)
        let silence = [Float](repeating: 0, count: 48 * 50 * 2)  // 50 ms stereo
        let accepted = silence.withUnsafeBufferPointer { p.write(interleaved: $0, channels: 2) }
        #expect(accepted == 960)
        #expect(p.stats.framesDropped == UInt64(48 * 50 - 960))
        await p.close()
        #expect(!p.write(opusPacket: [0xF4]))                   // closed
    }

    @Test func flushDropsQueuedAudio() async throws {
        let sink = Sink()
        let p = try pump(sink, queueMs: 200)
        let block = [Float](repeating: 0.1, count: 48 * 100 * 2)
        _ = block.withUnsafeBufferPointer { p.write(interleaved: $0, channels: 2) }
        p.flush()
        #expect(p.stats.queuedFrames == 0)
        #expect(p.stats.estimatedLatencyMilliseconds >= 10)
        await p.close()
    }
}
