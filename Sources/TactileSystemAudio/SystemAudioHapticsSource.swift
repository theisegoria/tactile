// System audio → haptics through ScreenCaptureKit audio capture.
//
// PERMISSION: capturing other apps' audio needs the Screen Recording
// permission (System Settings › Privacy & Security › Screen & System Audio
// Recording). The first start() shows the system prompt; after granting it the
// user may have to relaunch the app. Check `hasPermission` before starting
// and explain why the permission is needed. Sandboxed apps need no extra
// entitlement, but the app must be signed for the grant to persist.
//
// The stream captures audio only in effect: video is configured to a 2x2
// frame at one frame per second and no screen output is attached.

import CoreGraphics
public import CoreMedia
import Foundation
public import ScreenCaptureKit
import Synchronization
public import TactileHaptics

/// Streams system audio (everything except this process, or one app) into a
/// haptics mixer through a filter chain. Uses the mixer's stream: don't run
/// another stream producer (AudioTapSource, a pattern player) at the same time.
public final class SystemAudioHapticsSource: NSObject, @unchecked Sendable {
    public enum Target: Sendable, Hashable, Codable {
        /// All system audio except this app's own.
        case allSystemAudio
        /// Only the audio of the app with this bundle identifier.
        case application(bundleIdentifier: String)
    }

    public struct Configuration: Sendable, Hashable {
        public var target: Target
        public var filter: HapticFilterSettings
        /// 8000, 16000, 24000 or 48000 (ScreenCaptureKit's supported rates).
        public var sampleRate: Int
        /// 1 or 2.
        public var channelCount: Int

        public init(target: Target = .allSystemAudio, filter: HapticFilterSettings = .music,
                    sampleRate: Int = 48000, channelCount: Int = 2) {
            self.target = target
            self.filter = filter
            self.sampleRate = [8000, 16000, 24000, 48000].contains(sampleRate) ? sampleRate : 48000
            self.channelCount = channelCount == 1 ? 1 : 2
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Screen Recording permission not granted.
        case permissionDenied
        /// No display to attach the capture filter to.
        case noDisplay
        /// The target app is not running (or not capturable).
        case applicationNotFound(String)
        case captureFailed(String)
    }

    /// An app whose audio can be captured.
    public struct AudioApplication: Sendable, Hashable, Identifiable {
        public var bundleIdentifier: String
        public var name: String
        public var processID: Int32
        public var id: String { bundleIdentifier }
    }

    public let mixer: HapticsMixer
    public let configuration: Configuration
    private let pipeline: HapticAudioPipeline
    private let pendingFilter = Mutex<HapticFilterSettings?>(nil)
    private let queue = DispatchQueue(label: "tactile.system-audio", qos: .userInteractive)
    // SCStream is not Sendable; guarded by `lock`.
    private let lock = NSLock()
    private var activeStream: SCStream?
    private let level = Atomic<UInt32>(0)
    private let stoppedError = Mutex<String?>(nil)

    /// Creates the source. Nothing is captured until `start()`.
    public init(mixer: HapticsMixer, configuration: Configuration = Configuration()) {
        self.mixer = mixer
        self.configuration = configuration
        pipeline = HapticAudioPipeline(mixer: mixer, inputRate: Double(configuration.sampleRate),
                                       settings: configuration.filter)
        super.init()
    }

    // MARK: Permission

    /// Whether Screen Recording permission is granted (no prompt).
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; returns the current grant.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Apps whose audio can be captured (excluding this one). Needs the permission.
    public static func capturableApplications() async throws -> [AudioApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = ProcessInfo.processInfo.processIdentifier
        return content.applications
            .filter { $0.processID != me && !$0.bundleIdentifier.isEmpty }
            .map { AudioApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.applicationName, processID: $0.processID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Control

    public var isRunning: Bool { lock.withLock { activeStream != nil } }

    /// Changes the filter chain while running (applied on the next buffer).
    public func updateFilter(_ settings: HapticFilterSettings) {
        pendingFilter.withLock { $0 = settings }
    }

    /// Linear peak envelope after the filter chain (0…), for a level meter.
    public var currentLevel: Float { Float(bitPattern: level.load(ordering: .relaxed)) }

    /// 3 kHz frames dropped because the mixer stream was full.
    public var droppedFrames: Int { pipeline.input.droppedFrames }

    /// The error that stopped the stream, if ScreenCaptureKit stopped it.
    public var stopReason: String? { stoppedError.withLock { $0 } }

    /// Starts capture. Throws `.permissionDenied` without Screen Recording
    /// permission (call `requestPermission()` first).
    public func start() async throws {
        guard !isRunning else { return }
        guard Self.hasPermission else { throw Failure.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Failure.captureFailed("\(error)")
        }
        guard let display = content.displays.first else { throw Failure.noDisplay }
        let filter: SCContentFilter
        switch configuration.target {
        case .allSystemAudio:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case let .application(bundleID):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw Failure.applicationNotFound(bundleID)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = configuration.sampleRate
        config.channelCount = configuration.channelCount
        // Minimal video: the stream requires a video configuration.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            stoppedError.withLock { $0 = nil }
            try await stream.startCapture()
        } catch {
            throw Failure.captureFailed("\(error)")
        }
        lock.withLock { activeStream = stream }
    }

    /// Stops capture and drops queued haptic audio.
    public func stop() async {
        guard let stream = lock.withLock({ () -> SCStream? in defer { activeStream = nil }; return activeStream }) else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        queue.sync { _ = pipeline.flush() }
        mixer.stream.requestClear()
    }

    // MARK: Sample handling (on `queue`)

    /// Feeds one captured audio buffer through the pipeline.
    fileprivate func handle(_ sampleBuffer: CMSampleBuffer) {
        if let s = pendingFilter.withLock({ p -> HapticFilterSettings? in defer { p = nil }; return p }) {
            pipeline.update(s)
        }
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM else { return }
        pipeline.reconfigure(inputRate: asbd.mSampleRate)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard isFloat, asbd.mBitsPerChannel == 32, channels > 0 else { return }
        try? sampleBuffer.withAudioBufferList { abl, _ in
            if nonInterleaved {
                let planes = abl.compactMap { buf -> UnsafeBufferPointer<Float>? in
                    guard let p = buf.mData else { return nil }
                    return UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self),
                                               count: Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                }
                pipeline.process(channels: planes)
            } else if let buf = abl.first, let p = buf.mData {
                let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let frames = total / channels
                let src = UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: total)
                let planar = (0..<min(channels, 2)).map { c in (0..<frames).map { src[$0 * channels + c] } }
                planar[0].withUnsafeBufferPointer { l in
                    if planar.count > 1 {
                        planar[1].withUnsafeBufferPointer { r in _ = pipeline.process(channels: [l, r]) }
                    } else {
                        pipeline.process(channels: [l])
                    }
                }
            }
        }
        level.store(pipeline.chain.lastEnvelope.bitPattern, ordering: .relaxed)
    }
}

extension SystemAudioHapticsSource: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        handle(sampleBuffer)
    }
}

extension SystemAudioHapticsSource: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stoppedError.withLock { $0 = "\(error)" }
        lock.withLock { if activeStream === stream { activeStream = nil } }
    }
}
