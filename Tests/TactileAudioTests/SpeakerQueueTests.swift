import Foundation
import Testing
import TactileCore
@testable import TactileAudio

@Suite struct SpeakerQueueTests {
    func stereo(_ frames: Int, amp: Float = 0.3) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in let v = amp * Float(sin(Double(i) * 0.07)); return [v, v] }
    }

    /// macOS's encoder at 160 kb/s CBR gives exactly the 200-byte CELT frames
    /// (TOC 0xF4) the public implementations put in report 0x36.
    @Test func encodesFixed200ByteCELTFrames() throws {
        let q = try SpeakerQueue()
        let pcm = stereo(480 * 4 + 100)
        #expect(pcm.withUnsafeBufferPointer { q.write(interleaved: $0, channels: 2) } == 480 * 4 + 100)
        #expect(q.stats.queuedFrames == 480 * 4 + 100)       // 4 packets + a partial one
        for _ in 0..<4 {
            let p = try #require(q.nextPacket())
            #expect(p.opus.count == 200 && p.opus[0] == 0xF4)
            #expect(p.destination == .speaker)
        }
        #expect(q.stats.queuedFrames == 100)
    }

    @Test func underrunPadsWithSilenceThenEnds() throws {
        var o = SpeakerQueueOptions()
        o.idleMilliseconds = 32                                // 3 reports of 10.667 ms
        let q = try SpeakerQueue(options: o)
        #expect(q.nextPacket() == nil)                         // nothing written yet
        #expect(q.write(opusPacket: [0xF4, 1]))
        #expect(q.nextPacket()?.opus == [0xF4, 1])
        for _ in 0..<3 { #expect(q.nextPacket()?.opus.count == 200) }
        #expect(q.nextPacket() == nil)
        #expect(!q.stats.streaming)
        #expect(q.stats.silencePackets == 3 && q.stats.packetsTaken == 4)
        #expect(q.write(opusPacket: [0xF4, 2]))                // the next write restarts it
        #expect(q.nextPacket()?.opus == [0xF4, 2])
    }

    @Test func monoIsDuplicatedAndQueueIsBounded() throws {
        var o = SpeakerQueueOptions()
        o.queueMilliseconds = 32                               // 3 packets
        let q = try SpeakerQueue(options: o)
        let mono = [Float](repeating: 0.2, count: 480 * 5)
        let n = mono.withUnsafeBufferPointer { q.write(interleaved: $0, channels: 1) }
        #expect(n == 480 * 3)
        #expect(q.stats.framesDropped == UInt64(480 * 2))
        #expect(!q.write(opusPacket: [0xF4]))                 // full
        #expect(!q.write(opusPacket: [UInt8](repeating: 0, count: 256)))
    }

    @Test func destinationFlushAndClose() throws {
        let q = try SpeakerQueue()
        q.destination = .headphones
        _ = stereo(960).withUnsafeBufferPointer { q.write(interleaved: $0, channels: 2) }
        #expect(q.nextPacket()?.destination == .headphones)
        q.flush()
        #expect(q.stats.queuedFrames == 0)
        q.close()
        #expect(q.nextPacket() == nil)
        #expect(!q.write(opusPacket: [0xF4]))
    }

    @Test func timingConstants() {
        #expect(abs(SpeakerAudioFraming.packetPeriodSeconds - HapticsFormat.reportPeriodSeconds) < 1e-12)
        #expect(SpeakerQueue.inputSampleRate == 480 / SpeakerAudioFraming.packetPeriodSeconds)
    }
}
