import Foundation
import Synchronization
import Tactile
import TactileSystemAudio

/// What a system-audio-to-haptics operation captures and how it filters it.
/// The monitor carries live meters and filter changes between the running
/// operation and the card.
struct SystemAudioRequest: Sendable {
    var target: SystemAudioHapticsSource.Target
    var filter: HapticFilterSettings
    var monitor: SystemAudioMonitor
}

/// Shares the running `SystemAudioHapticsSource` with the UI: meters are read
/// from it and filter edits are forwarded to it. Empty when nothing runs.
final class SystemAudioMonitor: Sendable {
    private let source = Mutex<SystemAudioHapticsSource?>(nil)

    func attach(_ s: SystemAudioHapticsSource) { source.withLock { $0 = s } }
    func detach() { source.withLock { $0 = nil } }

    var isAttached: Bool { source.withLock { $0 != nil } }
    /// Linear peak envelope after the filter chain.
    var level: Float { source.withLock { $0?.currentLevel ?? 0 } }
    /// Compressor gain reduction, dB.
    var gainReductionDB: Float { source.withLock { $0?.currentGainReductionDB ?? 0 } }
    var droppedFrames: Int { source.withLock { $0?.droppedFrames ?? 0 } }

    func updateFilter(_ settings: HapticFilterSettings) { source.withLock { $0?.updateFilter(settings) } }
}

/// The library's filter presets, plus Custom once a slider moves.
enum SystemAudioPreset: String, CaseIterable, Identifiable {
    case passthrough = "Passthrough", music = "Music", game = "Game", custom = "Custom"
    var id: String { rawValue }
    var settings: HapticFilterSettings? {
        switch self {
        case .passthrough: .passthrough
        case .music: .music
        case .game: .game
        case .custom: nil
        }
    }
    static func matching(_ settings: HapticFilterSettings) -> SystemAudioPreset {
        allCases.first { $0.settings == settings } ?? .custom
    }
}

extension HapticFilterSettings {
    /// One line for operation receipts.
    var summary: String {
        let band = switch mode {
        case .none: "no filter"
        case .lowPass: String(format: "low-pass %.0f Hz", highCutoff)
        case .bandPass: String(format: "band-pass %.0f–%.0f Hz", lowCutoff, highCutoff)
        }
        let gate = gateThresholdDB <= -120 ? "gate off" : String(format: "gate %.0f dB", gateThresholdDB)
        return String(format: "%@; in %+.0f dB; comp %.0f dB %.1f:1; makeup %+.0f dB; %@", band, inputGainDB,
                      compressorThresholdDB, compressorRatio, makeupGainDB, gate)
    }
}

extension ControllerOperations {
    /// Captures system audio (or one app) into the controller's haptics mixer
    /// for `duration` seconds or until cancelled (Stop All). Runs inside
    /// `perform`, after the simulated early return, so simulation never
    /// starts capture.
    static func executeSystemAudio(_ request: SystemAudioRequest, on c: Controller, duration: Double) async throws -> OperationResult {
        guard SystemAudioHapticsSource.hasPermission else {
            throw LabError.invalid("Screen Recording permission is needed to capture system audio. Allow Tactile Lab in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch it.")
        }
        let source = SystemAudioHapticsSource(mixer: c.haptics, configuration: .init(target: request.target, filter: request.filter))
        try await c.startHaptics()
        do {
            try await source.start()
        } catch let failure as SystemAudioHapticsSource.Failure {
            throw LabError.invalid(describe(failure))
        }
        request.monitor.attach(source)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(duration)
        do {
            while clock.now < deadline, source.isRunning {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            request.monitor.detach()
            await source.stop()
            throw error
        }
        let reason = source.stopReason
        let dropped = source.droppedFrames
        request.monitor.detach()
        await source.stop()
        let summary = reason.map { "System audio capture stopped by macOS: \($0)." } ?? "System audio haptics ended. Felt result remains unverified."
        return OperationResult(summary: summary, metrics: ["systemAudioDroppedFrames": Double(dropped)])
    }

    private static func describe(_ failure: SystemAudioHapticsSource.Failure) -> String {
        switch failure {
        case .permissionDenied: "Screen Recording permission is not granted."
        case .noDisplay: "No display is available to attach the audio capture to."
        case .applicationNotFound(let id): "\(id) is not running or cannot be captured."
        case .captureFailed(let reason): "System audio capture failed: \(reason)"
        }
    }
}
