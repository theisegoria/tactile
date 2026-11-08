// EXPERIMENTAL (gate 6): a live speaker/headphone stream for engines.
//
// Report 0x36 carries haptics and one Opus frame every 10.667 ms, on the
// same grid as the haptics pump, so the pump sends it (see
// `Controller.attachSpeaker`). This queue is the audio side: the producer
// writes PCM at 45 kHz (480 samples per 10.667 ms report), which is encoded
// right away into CBR 160 kb/s stereo CELT frames of 200 bytes; the pump
// takes one frame per tick. Underruns are padded with encoded silence, and
// after `idleMilliseconds` of silence the stream ends until the next write.
// Report framing and timing come from public implementations and are
// unverified on hardware (PROTOCOL.md §Speaker).

import Foundation
import Synchronization
public import TactileCore

public struct SpeakerQueueOptions: Sendable, Hashable {
    /// CBR Opus bit rate; 160 kb/s gives the 200-byte frames the public
    /// implementations send.
    public var bitRate: Int = SpeakerAudioFraming.opusBitRate
    /// Most audio held in the queue, in ms.
    public var queueMilliseconds: Int = 250
    /// Silence sent after the queue empties before the stream ends, in ms.
    public var idleMilliseconds: Int = 500
    /// Speaker (0x93) or headphone jack (0x96).
    public var destination: SpeakerAudioFraming.Destination = .speaker
    public init() {}
}

public struct SpeakerQueueStats: Sendable, Hashable {
    /// Frames the pump has taken (each becomes one report 0x36).
    public var packetsTaken: UInt64 = 0
    /// Of those, padding silence because the queue was empty.
    public var silencePackets: UInt64 = 0
    /// Input frames refused because the queue was full (480 per refused packet).
    public var framesDropped: UInt64 = 0
    public var packetsDroppedOversize: UInt64 = 0
    public var encodeFailures: UInt64 = 0
    public var largestPacket: Int = 0
    /// Audio waiting, in 45 kHz input frames (whole packets plus the
    /// encoder's partial packet).
    public var queuedFrames: Int = 0
    public var streaming = false

    /// Queued audio in milliseconds of real time.
    public var queuedMilliseconds: Double { Double(queuedFrames) / SpeakerAudioFraming.inputSampleRate * 1000 }
}

public final class SpeakerQueue: SpeakerPacketSource, @unchecked Sendable {
    /// Rate of the PCM `write` expects: 480 samples per 10.667 ms report.
    public static let inputSampleRate = SpeakerAudioFraming.inputSampleRate
    public static let framesPerPacket = 480

    public let options: SpeakerQueueOptions
    private let silence: [UInt8]
    /// Producer side: the encoder and its partial packet.
    private let encoder: Mutex<OpusEncoder>
    private struct State {
        var packets: [[UInt8]] = []
        var head = 0
        var pendingFrames = 0       // in the encoder, not yet a packet
        var streaming = false
        var closed = false
        var idle = 0
        var destination: SpeakerAudioFraming.Destination
        var stats = SpeakerQueueStats()
        var count: Int { packets.count - head }
    }
    private let state: Mutex<State>

    public init(options: SpeakerQueueOptions = .init()) throws(OpusCodecError) {
        self.options = options
        let format = OpusStreamFormat.speaker  // encoded as 48 kHz stereo, 10 ms
        let e = try OpusEncoder(format: format, bitRate: options.bitRate, constantBitRate: true)
        let silent = try OpusEncoder(format: format, bitRate: options.bitRate, constantBitRate: true)
        guard let s = try silent.encode(interleaved: [Float](repeating: 0, count: Self.framesPerPacket * 2)).first else {
            throw .conversionFailed("silence frame")
        }
        silence = s
        encoder = Mutex(e)
        state = Mutex(State(destination: options.destination))
    }

    private var capacityPackets: Int {
        max(1, Int((Double(options.queueMilliseconds) / 1000 / SpeakerAudioFraming.packetPeriodSeconds).rounded(.down)))
    }
    private var idlePackets: Int {
        max(1, Int((Double(options.idleMilliseconds) / 1000 / SpeakerAudioFraming.packetPeriodSeconds).rounded(.up)))
    }

    public var destination: SpeakerAudioFraming.Destination {
        get { state.withLock { $0.destination } }
        set { state.withLock { $0.destination = newValue } }
    }

    /// Queues interleaved PCM at 45 kHz (`inputSampleRate`). 1 channel is
    /// duplicated; beyond 2 are dropped. Returns the frames accepted; the rest
    /// are counted as dropped. One producer at a time.
    @discardableResult
    public func write(interleaved samples: UnsafeBufferPointer<Float>, channels: Int) -> Int {
        guard channels > 0 else { return 0 }
        let frames = samples.count / channels
        let room: Int? = state.withLock { s in
            guard !s.closed else { return nil }
            return max(0, (capacityPackets - s.count) * Self.framesPerPacket - s.pendingFrames)
        }
        guard let room else { return 0 }
        let n = min(room, frames)
        var stereo = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let l = samples[i * channels], r = channels > 1 ? samples[i * channels + 1] : l
            stereo[2 * i] = l.isFinite ? max(-1, min(1, l)) : 0
            stereo[2 * i + 1] = r.isFinite ? max(-1, min(1, r)) : 0
        }
        let (packets, failed) = encoder.withLock { e -> ([[UInt8]], Bool) in
            do { return (try e.encode(interleaved: stereo), false) } catch { return ([], true) }
        }
        state.withLock { s in
            s.stats.framesDropped += UInt64(frames - n)
            if failed { s.stats.encodeFailures += 1; return }
            guard !s.closed else { return }
            s.pendingFrames = (s.pendingFrames + n) - packets.count * Self.framesPerPacket
            s.pendingFrames = max(0, s.pendingFrames)
            for p in packets { append(p, &s) }
            if n > 0 { s.streaming = true; s.idle = 0 }
        }
        return n
    }

    /// Queues one already-encoded Opus frame (48 kHz stereo, 10 ms, played
    /// over 10.667 ms). Returns false when closed, full, empty or over 255 bytes.
    @discardableResult
    public func write(opusPacket p: [UInt8]) -> Bool {
        state.withLock { s in
            guard !s.closed, !p.isEmpty else { return false }
            guard p.count <= 255 else { s.stats.packetsDroppedOversize += 1; return false }
            guard s.count < capacityPackets else {
                s.stats.framesDropped += UInt64(Self.framesPerPacket)
                return false
            }
            append(p, &s)
            s.streaming = true
            s.idle = 0
            return true
        }
    }

    private func append(_ p: [UInt8], _ s: inout State) {
        if s.head > 64, s.head * 2 > s.packets.count { s.packets.removeFirst(s.head); s.head = 0 }
        s.packets.append(p)
    }

    /// Drops everything queued (including the encoder's partial packet).
    public func flush() {
        encoder.withLock { e in _ = try? e.flush() }
        state.withLock { s in s.packets.removeAll(); s.head = 0; s.pendingFrames = 0 }
    }

    /// Ends the stream; later writes are refused and `nextPacket` returns nil.
    public func close() {
        state.withLock { s in s.closed = true; s.streaming = false; s.packets.removeAll(); s.head = 0; s.pendingFrames = 0 }
    }

    public var stats: SpeakerQueueStats {
        state.withLock { s in
            var r = s.stats
            r.queuedFrames = s.count * Self.framesPerPacket + s.pendingFrames
            r.streaming = s.streaming
            return r
        }
    }

    /// Called by the haptics pump once per 10.667 ms tick.
    public func nextPacket() -> SpeakerPacket? {
        state.withLock { s in
            guard !s.closed, s.streaming else { return nil }
            let opus: [UInt8]
            if s.count > 0 {
                opus = s.packets[s.head]
                s.head += 1
                s.idle = 0
            } else if s.idle < idlePackets {
                s.idle += 1
                opus = silence
                s.stats.silencePackets += 1
            } else {
                s.streaming = false
                return nil
            }
            s.stats.packetsTaken += 1
            s.stats.largestPacket = max(s.stats.largestPacket, opus.count)
            return SpeakerPacket(opus: opus, destination: s.destination)
        }
    }
}
