// Real-time playback of a haptic pattern: the haptic part (effects, audio
// clips, rumble) is rendered offline and streamed into the mixer, so live
// playback is sample-for-sample the preview; trigger and lightbar changes are
// sent on a clock alongside it.

import Foundation
import Synchronization
public import TactileCore

/// Where pattern trigger and lightbar changes go (a `Controller` in the
/// Tactile module, or a test double).
public protocol HapticPatternOutput: Sendable {
    func patternSetTrigger(_ side: TriggerSide, _ effect: TriggerEffect) async
    func patternSetLightbar(_ color: LightbarColor) async
}

/// Plays one pattern into a mixer. While playing it is the mixer stream's
/// producer, so do not run an `AudioTapSource`, `AudioFileSource` or
/// `PCMInput` on the same mixer at the same time. Parametric effects played
/// directly on the mixer still mix in.
public final class HapticPatternPlayer: Sendable {
    public let pattern: HapticPattern
    public let preview: HapticPreview
    public let controls: [HapticPatternControl]
    private let mixer: HapticsMixer
    private let output: (any HapticPatternOutput)?
    private struct State {
        var task: Task<Void, Never>?
        var generation: UInt64 = 0
        var playing = false
    }
    private let state = Mutex(State())

    /// How far ahead of the playhead PCM is queued.
    public static let lookahead: Double = 0.1

    /// Renders the pattern up front (throws if a clip cannot be loaded).
    public init(pattern: HapticPattern, mixer: HapticsMixer, output: (any HapticPatternOutput)?,
                clipLoader: @escaping HapticClipLoader = HapticPatternRenderer.fileClipLoader(relativeTo: nil)) throws {
        self.pattern = pattern
        self.mixer = mixer
        self.output = output
        preview = try HapticPatternRenderer.renderOffline(pattern, clipLoader: clipLoader)
        controls = pattern.controlTimeline()
    }

    /// Uses an existing render of `pattern` (e.g. one shared by several players).
    public init(pattern: HapticPattern, preview: HapticPreview, mixer: HapticsMixer, output: (any HapticPatternOutput)?) {
        self.pattern = pattern
        self.mixer = mixer
        self.output = output
        self.preview = preview
        controls = pattern.controlTimeline()
    }

    public var isPlaying: Bool { state.withLock { $0.playing } }

    /// Starts playback in a background task (restarting if already playing).
    public func start() {
        stop()
        state.withLock { s in
            s.generation &+= 1
            let generation = s.generation
            s.playing = true
            s.task = Task { [self] in
                await self.run()
                self.state.withLock { if $0.generation == generation { $0.playing = false } }
            }
        }
    }

    /// Stops playback and drops PCM still queued in the mixer stream.
    public func stop() {
        let t = state.withLock { s -> Task<Void, Never>? in
            defer { s.task = nil; s.playing = false; s.generation &+= 1 }
            return s.task
        }
        guard let t else { return }
        t.cancel()
        mixer.stream.requestClear()
    }

    /// Waits until the current playback (if any) has finished or been stopped.
    public func waitUntilFinished() async {
        let t = state.withLock { $0.task }
        await t?.value
    }

    /// Plays to the end in the calling task. Cancelling the task stops it
    /// (queued PCM is then dropped).
    public func play() async {
        await run()
        if Task.isCancelled { mixer.stream.requestClear() }
    }

    private func run() async {
        let pcm = preview.interleaved
        let rate = preview.sampleRate
        let totalFrames = preview.frameCount
        let clock = ContinuousClock()
        let start = clock.now
        var written = 0
        var nextControl = 0
        // Trigger/lightbar changes trail the PCM by the mixer's jitter buffer.
        let controlDelay = Double(mixer.streamPrefillFrames) / rate
        func elapsed() -> Double {
            let d = clock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }
        while !Task.isCancelled {
            let now = elapsed()
            let target = min(totalFrames, Int((now + Self.lookahead) * rate))
            if target > written {
                let chunk = Array(pcm[(written * 2)..<(target * 2)])
                let accepted = mixer.stream.write(chunk) / 2
                written += accepted
            }
            while nextControl < controls.count, controls[nextControl].time + controlDelay <= now {
                let c = controls[nextControl]
                nextControl += 1
                switch c.change {
                case let .trigger(side, effect): await output?.patternSetTrigger(side, effect)
                case let .lightbar(color): await output?.patternSetLightbar(color)
                }
            }
            if written >= totalFrames, nextControl >= controls.count { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if Task.isCancelled { return }
        if totalFrames > 0 { mixer.finishStream() }
        // Let the queued tail play out.
        while !Task.isCancelled, mixer.stream.availableToRead > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
