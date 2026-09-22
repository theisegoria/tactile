// AVAudioEngine-backed sources: audio-reactive haptics from any engine node
// (e.g. the main mixer or the microphone) and file playback.

public import AVFAudio
import Foundation

/// Taps an `AVAudioNode` and streams its audio into the haptics mixer.
/// The tap block runs on an AVFoundation-owned thread, not the audio I/O thread.
public final class AudioTapSource: @unchecked Sendable {
    public let engine: AVAudioEngine
    public let node: AVAudioNode
    public let bus: AVAudioNodeBus
    private let input: PCMInput
    private var installed = false

    /// - Parameters:
    ///   - node: typically `engine.mainMixerNode` (game audio) or `engine.inputNode` (microphone).
    ///   - gain: applied before resampling; audio-reactive haptics often want > 1.
    public init(engine: AVAudioEngine, node: AVAudioNode, bus: AVAudioNodeBus = 0, mixer: HapticsMixer, gain: Float = 1) {
        self.engine = engine
        self.node = node
        self.bus = bus
        let rate = node.outputFormat(forBus: bus).sampleRate
        input = PCMInput(mixer: mixer, inputRate: rate > 0 ? rate : 48000)
        mixer.setStreamGain(gain)
    }

    /// Installs the tap. Returns false (and installs nothing) when the node has
    /// no usable format yet, e.g. `inputNode` without microphone access reports 0 Hz.
    @discardableResult
    public func start() -> Bool {
        guard !installed else { return true }
        let format = node.outputFormat(forBus: bus)
        guard StreamingResampler.isSupported(rate: format.sampleRate), format.channelCount > 0 else { return false }
        input.reconfigure(inputRate: format.sampleRate)
        let input = self.input
        node.installTap(onBus: bus, bufferSize: 512, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let chans = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
            input.feed(channels: chans)
        }
        installed = true
        return true
    }

    public func stop() {
        guard installed else { return }
        node.removeTap(onBus: bus)
        installed = false
    }

    public var droppedFrames: Int { input.droppedFrames }
}

/// Streams an audio file into the mixer in real time (paced by buffer space).
public enum AudioFileSource {
    public enum Failure: Error { case unreadable(String) }

    /// Plays `url` through the haptics mixer. Returns when the file has been
    /// fully queued and drained, or when `shouldStop` returns true.
    public static func play(url: URL, mixer: HapticsMixer, gain: Float = 1,
                            shouldStop: @Sendable () -> Bool = { false }) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable("\(error)") }
        let format = file.processingFormat
        let input = PCMInput(mixer: mixer, inputRate: format.sampleRate)
        mixer.setStreamGain(gain)
        let chunk: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.unreadable("cannot allocate buffer")
        }
        // Keep ~200 ms queued: enough to ride out scheduling hiccups, small
        // enough that stopping is responsive.
        let targetBuffered = Int(0.2 * 3000) * 2
        while file.framePosition < file.length, !shouldStop() {
            while mixer.stream.availableToRead > targetBuffered, !shouldStop() {
                try await Task.sleep(for: .milliseconds(10))
            }
            try file.read(into: buffer, frameCount: chunk)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let frames = Int(buffer.frameLength)
            let chans = (0..<Int(format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
            input.feed(channels: chans)
        }
        if !shouldStop() {
            input.flush()          // the last ~4.5 ms still inside the filter
            mixer.finishStream()   // play a clip shorter than the prefill right away
        }
        while mixer.stream.availableToRead > 0, !shouldStop() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
