import AVFAudio
import Foundation
import Tactile

/// Every output job and cleanup joins the preceding barrier. Actor re-entry
/// cannot let an old cleanup reset a newer effect or write to a new selection.
actor ControllerOperations {
    private var target: LabTarget?
    private var active: Task<OperationResult, any Error>?
    private var barrier: Task<Void, Never>?
    private var generation: UInt64 = 0

    func select(_ newTarget: LabTarget?) async {
        generation &+= 1
        active?.cancel()
        active = nil
        let previous = barrier
        let oldTarget = target
        target = newTarget
        let cleanup = Task.detached {
            await previous?.value
            await Self.reset(oldTarget)
        }
        barrier = cleanup
        await cleanup.value
    }

    func stop() async {
        generation &+= 1
        active?.cancel()
        active = nil
        let previous = barrier
        let currentTarget = target
        let cleanup = Task.detached {
            await previous?.value
            await Self.reset(currentTarget)
        }
        barrier = cleanup
        await cleanup.value
    }

    func perform(_ command: LabCommand, duration: Double) async throws -> OperationResult {
        guard duration.isFinite, (0.1...60).contains(duration) else { throw LabError.invalid("Duration must be 0.1–60 seconds.") }
        guard let target else { throw LabError.noController }
        generation &+= 1
        let current = generation
        active?.cancel()
        let previous = barrier
        let job = Task.detached {
            await previous?.value
            try Task.checkCancellation()
            do {
                let result = try await Self.execute(command, on: target, duration: duration)
                await Self.reset(target)
                return result
            } catch {
                await Self.reset(target)
                throw error
            }
        }
        active = job
        barrier = Task { _ = try? await job.value }
        let result = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        if current == generation { active = nil }
        return result
    }

    private static func reset(_ target: LabTarget?) async {
        guard let controller = target?.controller else { return }
        await controller.stopHaptics()
        await controller.neutralize()
    }

    private static func execute(_ command: LabCommand, on target: LabTarget, duration: Double) async throws -> OperationResult {
        if case .simulated(_, let fails) = target {
            if fails { throw LabError.simulatedFailure }
            try await Task.sleep(for: .seconds(duration))
            return OperationResult(summary: "Simulated request completed; no controller output was sent.")
        }
        guard let c = target.controller, c.isConnected else { throw LabError.noController }
        let result: OperationResult
        switch command {
        case .output(let output):
            if let rumble = output.rumble { try await c.setRumble(rumble) }
            var other = output; other.rumble = nil
            if other != OutputState() { try await c.apply(other) }
            try await Task.sleep(for: .seconds(duration))
            result = OperationResult(summary: "HID request completed. Physical response needs your observation.")
        case .haptic(let effect, let side):
            try await c.play(effect, side: side)
            try await Task.sleep(for: .seconds(duration))
            result = OperationResult(summary: "Haptics request completed. Felt result remains unverified.")
        case .hapticFile(let url, let gain):
            try await c.startHaptics()
            _ = try await boundedPlayback(duration: duration) {
                try await AudioFileSource.play(url: url, mixer: c.haptics, gain: gain, shouldStop: { Task.isCancelled })
            }
            result = OperationResult(summary: "Audio-to-haptics playback ended. Felt result remains unverified.")
        case .hostMicrophone(let gain):
            let engine = AVAudioEngine()
            let source = AudioTapSource(engine: engine, node: engine.inputNode, mixer: c.haptics, gain: gain)
            guard source.start() else { throw LabError.invalid("No microphone input is available. Allow microphone access in System Settings, then retry.") }
            defer { source.stop(); engine.stop() }
            try engine.start()
            try await c.startHaptics()
            try await Task.sleep(for: .seconds(duration))
            result = OperationResult(summary: "Host microphone haptics ended. Felt result remains unverified.")
        case .speaker(let url, let framing, let bitRate, let gain, let routing):
            guard framing.isValid else { throw LabError.invalid("Speaker framing has no room for its header, length prefix, payload and CRC.") }
            try await c.setAudio(routing)
            let stats = try await boundedPlayback(duration: duration) {
                try await c.playSpeakerAudio(url: url, framing: framing, bitRate: bitRate, gain: gain)
            }
            result = OperationResult(summary: "Experimental speaker stream \(stats.map { $0.description } ?? "reached its time limit; partial packet counts unavailable"). Audible result remains unverified.",
                                     metrics: stats.map { ["speakerPacketsSent": Double($0.packetsSent), "speakerOversizedPackets": Double($0.packetsDroppedOversize), "speakerSendFailures": Double($0.sendFailures), "speakerMaxLatenessMs": $0.maxLatenessMs] } ?? [:])
        case .scan:
            try await c.setAudio(AudioSettings(micVolume: 64))
            let scan = await c.scanForMicUplink(duration: .seconds(duration))
            try Task.checkCancellation()
            result = OperationResult(summary: "Found \(scan.candidates.count) candidate layouts. These are hypotheses, not confirmed audio.",
                                     candidates: scan.candidates, reportCounts: scan.counts)
        case .record(let extractor, let format, let url):
            try format.validate()
            try await c.setAudio(AudioSettings(micVolume: 64))
            let stats = try await c.recordMicUplink(extractor: extractor, format: format, to: url, duration: .seconds(duration))
            result = OperationResult(summary: stats.description, recording: url)
        }
        var measured = result
        measured.metrics.merge(metricValues(c.hapticsMetrics()), uniquingKeysWith: { _, newer in newer })
        return measured
    }

    /// These producers explicitly observe cancellation; structured cleanup is
    /// appropriate here. Application termination uses a separate deadline.
    private static func boundedPlayback<T: Sendable>(duration: Double, body: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(duration)); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
