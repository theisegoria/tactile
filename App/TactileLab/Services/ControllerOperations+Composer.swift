import AVFAudio
import Foundation
import Tactile

/// What a composition sends: the rendered actuator mix plus timed output
/// changes for the trigger and lightbar tracks.
struct ComposerPlaybackPlan: Sendable {
    var actuatorFile: URL
    var outputKeys: [ComposerOutputKey]
    var length: Double
}

struct ComposerOutputKey: Sendable {
    var time: Double
    var state: OutputState
}

// MARK: Composer

/// Executors for the Composer and the Speaker panel that `LabCommand` cannot
/// reach yet. They are not called anywhere today. To wire them (main session,
/// which owns LabModels.swift and ControllerOperations.swift):
///
///     // LabCommand
///     case composition(ComposerPlaybackPlan)
///     case sharedSpeaker(URL, Float, AudioSettings, SpeakerAudioFraming.Destination)
///     // ControllerOperations.execute, after the simulated early return
///     case .composition(let plan): result = try await Self.executeComposition(plan, on: c, duration: duration)
///     case .sharedSpeaker(let url, let gain, let routing, let destination):
///         result = try await Self.executeSharedSpeaker(url: url, gain: gain, routing: routing, destination: destination, on: c, duration: duration)
///
/// Both run inside `perform`, so they inherit its barrier, cancellation,
/// Stop All reset and the simulated path (which sends nothing).
extension ControllerOperations {
    static func executeComposition(_ plan: ComposerPlaybackPlan, on c: Controller, duration: Double) async throws -> OperationResult {
        let length = min(duration, plan.length)
        try await c.startHaptics()
        let keys = plan.outputKeys.sorted { $0.time < $1.time }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await AudioFileSource.play(url: plan.actuatorFile, mixer: c.haptics, gain: 1, shouldStop: { Task.isCancelled })
            }
            group.addTask {
                let clock = ContinuousClock()
                let start = clock.now
                for key in keys where key.time < length {
                    try await clock.sleep(until: start + .milliseconds(Int((key.time * 1000).rounded())))
                    try await c.apply(key.state)
                }
            }
            try await Task.sleep(for: .seconds(length))
            group.cancelAll()
        }
        return OperationResult(summary: "Composition played (\(keys.count) output changes). Felt result remains unverified.")
    }

    /// Speaker playback on the shared haptics stream (0.3): the file is
    /// resampled to 45 kHz stereo and queued into a `SpeakerQueue` attached to
    /// the haptics pump, which sends report 0x36 in place of 0x32 while audio
    /// is queued. Unverified on hardware.
    static func executeSharedSpeaker(url: URL, gain: Float, routing: AudioSettings, destination: SpeakerAudioFraming.Destination,
                                     on c: Controller, duration: Double) async throws -> OperationResult {
        let pcm = try decodeStereo(url: url, rate: SpeakerQueue.inputSampleRate, gain: gain)
        try await c.setAudio(routing)
        var options = SpeakerQueueOptions()
        options.destination = destination
        let queue = try SpeakerQueue(options: options)
        try await c.attachSpeaker(queue)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(duration)
        var position = 0
        let chunk = Int(SpeakerQueue.inputSampleRate / 10) * 2  // 100 ms, interleaved
        do {
            while position < pcm.count, clock.now < deadline {
                try Task.checkCancellation()
                if queue.stats.queuedMilliseconds > 150 { try await Task.sleep(for: .milliseconds(10)); continue }
                let end = min(pcm.count, position + chunk)
                let accepted = pcm[position..<end].withUnsafeBufferPointer { queue.write(interleaved: $0, channels: 2) }
                position += max(accepted, 1) * 2
            }
            queue.flush()
            while queue.stats.queuedFrames > 0, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await c.detachSpeaker(ifAttached: queue); queue.close()
            throw error
        }
        let stats = queue.stats
        await c.detachSpeaker(ifAttached: queue); queue.close()
        return OperationResult(summary: "Shared-stream speaker playback ended: \(stats.packetsTaken) packets, \(stats.silencePackets) silent. Audible result remains unverified.",
                               metrics: ["speakerPacketsSent": Double(stats.packetsTaken), "speakerSilencePackets": Double(stats.silencePackets),
                                         "speakerFramesDropped": Double(stats.framesDropped), "speakerOversizedPackets": Double(stats.packetsDroppedOversize),
                                         "speakerEncodeFailures": Double(stats.encodeFailures)])
    }

    /// Decodes and converts a file to interleaved stereo Float32 at `rate`.
    private static func decodeStereo(url: URL, rate: Double, gain: Float) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw LabError.invalid("Cannot convert \(url.lastPathComponent) for the speaker.")
        }
        let inCapacity: AVAudioFrameCount = 8192
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(inCapacity) * rate / file.processingFormat.sampleRate) + 1024) else {
            throw LabError.invalid("Cannot allocate audio buffers.")
        }
        var samples: [Float] = []
        var finished = false
        let limit = Int(rate * 60) * 2
        while samples.count < limit {
            var readError: (any Error)?
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                if finished { inputStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: inCapacity) } catch { readError = error }
                if input.frameLength == 0 { finished = true; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if let data = output.floatChannelData, output.frameLength > 0 {
                let n = Int(output.frameLength) * 2
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n).map { $0 * gain })
            }
            if status == .endOfStream || status == .error || (finished && output.frameLength == 0) { break }
        }
        return samples
    }
}
