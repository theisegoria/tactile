// EXPERIMENTAL (gate 6): a live speaker/headphone stream for engines.
//
// `SpeakerStream` plays a finished sequence; an engine instead produces audio
// block by block. `SpeakerPump` keeps a bounded queue of 48 kHz PCM (or of
// pre-encoded 10 ms Opus packets), and while anything is queued it sends one
// report 0x36 every 10 ms on a deadline grid. Underruns are padded with
// silence; after `idleMilliseconds` of silence the stream ends and restarts on
// the next write. Report framing is 🔬 unverified (PROTOCOL.md, gate 6).

import Foundation
import Synchronization
public import TactileCore

public struct SpeakerPumpOptions: Sendable, Hashable {
    /// Opus bit rate; 96 kb/s gives about 120-byte packets.
    public var bitRate: Int = 96_000
    /// Most audio held in the queue (PCM frames or Opus packets), in ms.
    public var queueMilliseconds: Int = 250
    /// Silence sent after the queue empties before the stream ends, in ms.
    public var idleMilliseconds: Int = 500
    public init() {}
}

public struct SpeakerPumpStats: Sendable, Hashable {
    public var packetsSent: UInt64 = 0
    /// Packets of padding silence sent because the queue was empty.
    public var silencePackets: UInt64 = 0
    /// PCM frames refused because the queue was full (plus 480 per refused Opus packet).
    public var framesDropped: UInt64 = 0
    public var packetsDroppedOversize: UInt64 = 0
    public var sendFailures: UInt64 = 0
    public var largestPacket: Int = 0
    /// Audio waiting to be sent, in 48 kHz frames.
    public var queuedFrames: Int = 0
    public var streaming = false
    /// Mean time from a report's deadline to its set-report completing.
    public var sendLatencyMeanUs: Double = 0
    public var sendLatencyMaxUs: Double = 0

    /// Queued audio in milliseconds.
    public var queuedMilliseconds: Double { Double(queuedFrames) / 48.0 }
    /// Estimated time from a write to the report leaving the host: the queue,
    /// one packet of grid wait and the mean send latency. The air link and
    /// the controller's decoder are not included (unmeasured).
    public var estimatedLatencyMilliseconds: Double { queuedMilliseconds + 10 + sendLatencyMeanUs / 1000 }
}

public final class SpeakerPump: Sendable {
    public typealias Send = @Sendable ([UInt8]) async throws -> Void

    public let framing: SpeakerAudioFraming
    public let format: OpusStreamFormat
    public let options: SpeakerPumpOptions
    private let send: Send

    private struct State {
        var pcm: [Float] = []           // interleaved stereo
        var opus: [[UInt8]] = []
        var streaming = false
        var closed = false
        var generation: UInt64 = 0
        var stats = SpeakerPumpStats()
        var latencySum: Double = 0
        var task: Task<Void, Never>?
        /// Carries the 4-bit report sequence across stream restarts.
        var builder: SpeakerAudioReportBuilder
    }
    private let state: Mutex<State>

    public init(framing: SpeakerAudioFraming, format: OpusStreamFormat = .speaker,
                options: SpeakerPumpOptions = .init(), send: @escaping Send) throws(OpusCodecError) {
        try format.validate()
        guard format.channels == 2 else { throw .unsupportedFormat("speaker pump needs stereo") }
        // Fail early if the system encoder is unavailable.
        _ = try OpusEncoder(format: format, bitRate: options.bitRate)
        state = Mutex(State(builder: SpeakerAudioReportBuilder(framing: framing)))
        self.framing = framing
        self.format = format
        self.options = options
        self.send = send
    }

    private var framesPerPacket: Int { format.framesPerPacket }
    private var capacityFrames: Int { max(framesPerPacket, Int(format.sampleRate) * options.queueMilliseconds / 1000) }
    private var idlePackets: Int { max(1, options.idleMilliseconds / max(1, Int(format.frameMilliseconds))) }

    /// Queues interleaved PCM at the format's rate (48 kHz). `channels` 1 is
    /// duplicated to both sides; beyond 2, extra channels are dropped. Returns
    /// the frames accepted (the rest are counted as dropped).
    @discardableResult
    public func write(interleaved samples: UnsafeBufferPointer<Float>, channels: Int) -> Int {
        guard channels > 0 else { return 0 }
        let frames = samples.count / channels
        let accepted: Int? = state.withLock { s in
            guard !s.closed else { return nil }
            let room = max(0, capacityFrames - queued(s))
            let n = min(room, frames)
            s.pcm.reserveCapacity(s.pcm.count + n * 2)
            for i in 0..<n {
                let l = samples[i * channels]
                let r = channels > 1 ? samples[i * channels + 1] : l
                s.pcm.append(l.isFinite ? max(-1, min(1, l)) : 0)
                s.pcm.append(r.isFinite ? max(-1, min(1, r)) : 0)
            }
            s.stats.framesDropped += UInt64(frames - n)
            if n > 0 { startLocked(&s) }
            return n
        }
        return accepted ?? 0
    }

    /// Queues one already-encoded Opus packet (CELT, 48 kHz stereo, 10 ms).
    /// Returns false when closed, the queue is full or the packet cannot fit
    /// the report.
    @discardableResult
    public func write(opusPacket p: [UInt8]) -> Bool {
        state.withLock { s in
            guard !s.closed, !p.isEmpty else { return false }
            guard p.count <= framing.maxPacketBytes else { s.stats.packetsDroppedOversize += 1; return false }
            guard queued(s) + framesPerPacket <= capacityFrames else {
                s.stats.framesDropped += UInt64(framesPerPacket)
                return false
            }
            s.opus.append(p)
            startLocked(&s)
            return true
        }
    }

    /// Drops everything queued. The stream pads with silence and ends after
    /// the idle time.
    public func flush() {
        state.withLock { s in s.pcm.removeAll(); s.opus.removeAll() }
    }

    public var stats: SpeakerPumpStats {
        state.withLock { s in
            var r = s.stats
            r.queuedFrames = queued(s)
            r.streaming = s.streaming
            return r
        }
    }

    /// Stops the stream and waits for its task to finish. Later writes are refused.
    public func close() async {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.closed = true
            s.pcm.removeAll(); s.opus.removeAll()
            s.generation &+= 1
            let t = s.task
            s.task = nil
            return t
        }
        task?.cancel()
        await task?.value
    }

    private func queued(_ s: State) -> Int { s.pcm.count / 2 + s.opus.count * framesPerPacket }

    private func startLocked(_ s: inout State) {
        guard !s.streaming, !s.closed else { return }
        s.streaming = true
        s.generation &+= 1
        let gen = s.generation
        s.task = Task.detached(priority: .userInitiated) { [self] in await run(generation: gen) }
    }

    private enum Next { case packet([UInt8], silence: Bool), pcm([Float], silence: Bool), stop }

    private func run(generation gen: UInt64) async {
        guard let encoder = try? OpusEncoder(format: format, bitRate: options.bitRate) else {
            state.withLock { s in if s.generation == gen { s.streaming = false; s.stats.sendFailures += 1 } }
            return
        }
        var builder = state.withLock { $0.builder }
        let clock = ContinuousClock()
        let period = Duration.microseconds(Int64(format.frameMilliseconds * 1000))
        let n = framesPerPacket
        var deadline = clock.now
        var idle = 0
        while !Task.isCancelled {
            let next: Next = state.withLock { s in
                guard s.generation == gen, !s.closed else { return .stop }
                if !s.opus.isEmpty { idle = 0; return .packet(s.opus.removeFirst(), silence: false) }
                if !s.pcm.isEmpty {
                    idle = 0
                    let take = min(n * 2, s.pcm.count)
                    var chunk = Array(s.pcm.prefix(take))
                    s.pcm.removeFirst(take)
                    if chunk.count < n * 2 { chunk += [Float](repeating: 0, count: n * 2 - chunk.count) }
                    return .pcm(chunk, silence: false)
                }
                if idle >= idlePackets { s.streaming = false; s.task = nil; s.builder = builder; return .stop }
                idle += 1
                return .pcm([Float](repeating: 0, count: n * 2), silence: true)
            }
            let packet: [UInt8]
            let silence: Bool
            switch next {
            case .stop: return
            case .packet(let p, let sil): packet = p; silence = sil
            case .pcm(let chunk, let sil):
                guard let p = (try? encoder.encode(interleaved: chunk))?.first else {
                    state.withLock { $0.stats.sendFailures += 1 }
                    continue
                }
                packet = p; silence = sil
            }
            if clock.now < deadline { try? await clock.sleep(until: deadline) }
            guard !Task.isCancelled, state.withLock({ $0.generation == gen && !$0.closed }) else { return }
            let report: [UInt8]
            do { report = try builder.build(opusPacket: packet) } catch {
                state.withLock { $0.stats.packetsDroppedOversize += 1 }
                deadline += period
                continue
            }
            var ok = true
            do { try await send(report) } catch { ok = false }
            let latency = Double((clock.now - deadline).components.attoseconds) / 1e12
                + Double((clock.now - deadline).components.seconds) * 1e6
            state.withLock { s in
                guard s.generation == gen else { return }
                if ok {
                    s.stats.packetsSent += 1
                    if silence { s.stats.silencePackets += 1 }
                    s.stats.largestPacket = max(s.stats.largestPacket, packet.count)
                    s.latencySum += max(0, latency)
                    s.stats.sendLatencyMeanUs = s.latencySum / Double(s.stats.packetsSent)
                    s.stats.sendLatencyMaxUs = max(s.stats.sendLatencyMaxUs, latency)
                } else {
                    s.stats.sendFailures += 1
                }
            }
            deadline += period
            // Fell more than a packet behind: re-anchor instead of bursting.
            if clock.now > deadline + period { deadline = clock.now }
        }
    }
}
