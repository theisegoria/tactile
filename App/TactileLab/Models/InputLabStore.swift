import AppKit
import Foundation
import Observation
import Tactile
import UniformTypeIdentifiers

/// Collects input for the Input Lab, runs the analysis, records and replays.
///
/// Live input arrives through `ingest(_:at:)` and `ingestReports(_:)` (the
/// view forwards the session's readings); replay drives the same entry points
/// from a saved `InputLabRecording`, so every visual works without a controller.
@MainActor @Observable
final class InputLabStore {
    enum Source: Equatable { case live, replay }

    /// Library-backed analysis (`InputAnalysis`).
    let analyzer: TactileInputAnalyzer
    /// Analysis window: about a minute of frames at the display rate.
    var frameCapacity = 2_000
    var reportCapacity = 2_000
    var trailLength = 48

    private(set) var source: Source = .live
    private(set) var current: InputLabFrame?
    private(set) var frames: [InputLabFrame] = []
    private(set) var reportTimes: [Double] = []
    private(set) var results: InputLabResults
    private(set) var isRecording = false
    private(set) var recordedFrames = 0
    private(set) var measuringRest = false
    private(set) var replayProgress = 0.0
    private(set) var loadedRecording: InputLabRecording?
    private(set) var message: String?

    private var rest: [InputRecording.Sample] = []
    private var restUntil: Double?
    private var lastRawID: UInt64?
    private var origin: Double?
    private var recording: (start: Double, frames: [InputLabFrame], reports: [Double])?
    private var replayTask: Task<Void, Never>?
    private var lastAnalysis = -Double.infinity
    private let clock: @MainActor () -> Double

    init(analyzer: TactileInputAnalyzer = TactileInputAnalyzer(), clock: @escaping @MainActor () -> Double = { Date().timeIntervalSinceReferenceDate }) {
        self.analyzer = analyzer
        self.clock = clock
        results = InputLabResults.compute(frames: [], rest: [], reportTimes: [], analyzer: analyzer)
    }

    var trailLeft: [StickPoint] { frames.suffix(trailLength).map(\.left) }
    var trailRight: [StickPoint] { frames.suffix(trailLength).map(\.right) }
    var hasData: Bool { !frames.isEmpty }
    var restRemaining: Double { max(0, (restUntil ?? 0) - (current?.t ?? 0)) }

    // MARK: Live input

    /// Feeds one live input state. Ignored while a recording is replaying.
    func ingest(_ state: InputState?, at time: Double? = nil) {
        guard source == .live, let state else { return }
        let now = time ?? clock()
        if origin == nil { origin = now }
        let frame = InputLabFrame(state, t: now - (origin ?? now))
        append(frame)
        if var r = recording {
            var copy = frame; copy.t = now - r.start
            r.frames.append(copy)
            recording = r
            recordedFrames = r.frames.count
        }
    }

    /// Feeds the session's newest raw report rows; only rows not seen before count.
    func ingestReports(_ rows: [RawReportRow]) {
        guard source == .live, let newest = rows.last else { return }
        if let lastRawID, newest.id < lastRawID { self.lastRawID = nil }  // selection changed; ids restarted
        let fresh = rows.filter { row in lastRawID.map { row.id > $0 } ?? true }
        lastRawID = newest.id
        guard !fresh.isEmpty else { return }
        let times = fresh.map { $0.date.timeIntervalSinceReferenceDate }
        if origin == nil { origin = times[0] }
        appendReports(times.map { $0 - (origin ?? 0) })
        if var r = recording {
            r.reports.append(contentsOf: times.map { $0 - r.start })
            recording = r
        }
    }

    // MARK: Analysis controls

    /// Starts a rest window: leave both sticks untouched for `seconds`.
    func measureRest(seconds: Double = 3) {
        rest = []
        measuringRest = true
        restUntil = (current?.t ?? 0) + seconds
        message = "Leave both sticks untouched for \(Int(seconds)) seconds…"
    }

    func reset() {
        frames = []; reportTimes = []; rest = []
        restUntil = nil; measuringRest = false; current = nil; origin = nil; lastRawID = nil
        message = nil
        analyze(force: true)
    }

    func analyze(force: Bool = false) {
        let now = current?.t ?? 0
        guard force || now - lastAnalysis >= 0.25 || now < lastAnalysis else { return }
        lastAnalysis = now
        results = InputLabResults.compute(frames: frames, rest: rest, reportTimes: reportTimes, analyzer: analyzer)
    }

    // MARK: Recording

    func startRecording() {
        guard source == .live else { return }
        recording = (clock(), [], [])
        recordedFrames = 0
        isRecording = true
        message = "Recording input…"
    }

    /// Stops recording and returns the capture (nil if nothing was recorded).
    @discardableResult
    func stopRecording(device: LabDevice?) -> InputLabRecording? {
        defer { recording = nil; isRecording = false }
        guard let r = recording, !r.frames.isEmpty else { message = "Nothing was recorded."; return nil }
        let result = InputLabRecording(deviceName: device?.displayName ?? "Unknown controller", model: device?.model ?? "DualSense",
                                       simulated: device?.simulated ?? false, frames: r.frames, reportTimes: r.reports)
        loadedRecording = result
        message = "Recorded \(r.frames.count) frames over \(InputLabHealthReport.number(result.duration, 1)) s."
        return result
    }

    // MARK: Replay

    /// Replays a recording through the analysis at its original pace.
    /// `speed` > 1 replays faster; `instant` feeds everything at once (tests).
    func replay(_ recording: InputLabRecording, speed: Double = 1, instant: Bool = false) {
        stopReplay()
        if isRecording { stopRecording(device: nil) }
        loadedRecording = recording
        source = .replay
        clearForReplay()
        if instant {
            for frame in recording.frames { append(frame) }
            appendReports(recording.reportTimes)
            replayProgress = 1
            analyze(force: true)
            return
        }
        let frames = recording.frames, reports = recording.reportTimes, duration = max(recording.duration, 0.001)
        replayTask = Task { [weak self] in
            var reportIndex = 0
            var previous = 0.0
            for frame in frames {
                let wait = (frame.t - previous) / max(speed, 0.01)
                previous = frame.t
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled, self.source == .replay else { return }
                var due: [Double] = []
                while reportIndex < reports.count, reports[reportIndex] <= frame.t { due.append(reports[reportIndex]); reportIndex += 1 }
                self.appendReports(due)
                self.append(frame)
                self.replayProgress = frame.t / duration
            }
            guard let self, !Task.isCancelled else { return }
            self.appendReports(Array(reports[reportIndex...]))
            self.replayProgress = 1
            self.analyze(force: true)
            self.message = "Replay finished. Press Live to return to the controller."
        }
        message = "Replaying \(recording.deviceName)…"
    }

    func stopReplay() {
        replayTask?.cancel(); replayTask = nil
    }

    /// Returns to live input and clears the replayed data.
    func goLive() {
        stopReplay()
        source = .live
        replayProgress = 0
        reset()
    }

    // MARK: Files

    /// Saves as Input Lab JSON, or as the library's `InputRecording` when the
    /// URL ends in `.tactileinput` (frames only: report times are dropped).
    func save(_ recording: InputLabRecording, to url: URL) throws {
        let data = url.pathExtension == InputRecording.fileExtension ? try recording.libraryRecording.encoded() : try recording.encoded()
        try data.write(to: url, options: .atomic)
        message = "Saved \(url.lastPathComponent)."
    }

    /// Loads an Input Lab JSON recording or a library `.tactileinput` file.
    func load(from url: URL) throws -> InputLabRecording {
        let recording = try Self.decodeRecording(Data(contentsOf: url), pathExtension: url.pathExtension)
        loadedRecording = recording
        message = "Loaded \(url.lastPathComponent): \(recording.frames.count) frames."
        return recording
    }

    /// Picks the format by extension; for anything else, Input Lab JSON first, then the library format.
    nonisolated static func decodeRecording(_ data: Data, pathExtension: String) throws -> InputLabRecording {
        if pathExtension == InputRecording.fileExtension { return InputLabRecording(try InputRecording(data: data)) }
        do { return try InputLabRecording.decode(data) } catch let labError {
            guard let library = try? InputRecording(data: data) else { throw labError }
            return InputLabRecording(library)
        }
    }

    func clearMessage() { message = nil }
    func show(_ text: String) { message = text }

    // MARK: Health report

    func healthReport(session: LabSession) -> InputLabHealthReport {
        analyze(force: true)
        let device = session.selectedDevice
        let replaying = source == .replay
        let firmware = session.diagnostics.firmware.map { "\($0.updateVersionString) · firmware \(String($0.firmwareVersion, radix: 16)) · hardware \(String($0.hardwareVersion, radix: 16))" }
        let battery = current?.battery ?? session.readings.input?.battery?.percent
        let state = current?.charging ?? session.readings.input?.battery?.charging.rawValue
        return InputLabHealthReport(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            libraryVersion: TactileVersion.string,
            deviceName: replaying ? (loadedRecording?.deviceName ?? "Recording") : (device?.displayName ?? "No controller"),
            deviceID: replaying ? nil : device?.id,
            model: replaying ? (loadedRecording?.model ?? "DualSense") : (device?.model ?? "DualSense"),
            simulated: replaying ? (loadedRecording?.simulated ?? false) : session.simulated,
            source: replaying ? "Replayed recording" : "Live controller",
            firmware: replaying ? nil : firmware,
            batteryPercent: battery, batteryState: state,
            samples: frames.count, results: results)
    }

    static func write(_ report: InputLabHealthReport, to directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("Controller health \(report.generatedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.json().write(to: folder.appendingPathComponent("health.json"), options: .atomic)
        try report.markdown().write(to: folder.appendingPathComponent("health.md"), atomically: true, encoding: .utf8)
        return folder
    }

    // MARK: Private

    private func append(_ frame: InputLabFrame) {
        current = frame
        frames.append(frame)
        if frames.count > frameCapacity { frames.removeFirst(frames.count - frameCapacity) }
        if measuringRest, let until = restUntil {
            if frame.t <= until { rest.append(frame.sample) }
            else { measuringRest = false; restUntil = nil; message = "Rest measured from \(rest.count) samples."; analyze(force: true); return }
        }
        analyze()
    }

    private func appendReports(_ times: [Double]) {
        guard !times.isEmpty else { return }
        reportTimes.append(contentsOf: times)
        if reportTimes.count > reportCapacity { reportTimes.removeFirst(reportTimes.count - reportCapacity) }
    }

    private func clearForReplay() {
        frames = []; reportTimes = []; rest = []
        restUntil = nil; measuringRest = false; current = nil; origin = nil; lastRawID = nil
        replayProgress = 0; lastAnalysis = -.infinity
    }
}

/// File panels for the Input Lab (main-thread, modal).
@MainActor enum InputLabFiles {
    static let libraryType = UTType(filenameExtension: InputRecording.fileExtension, conformingTo: .json) ?? .json

    static func chooseSaveURL(suggested: String, library: Bool = false) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [library ? libraryType : .json]
        panel.nameFieldStringValue = suggested
        panel.message = library
            ? "Export the frames as a Tactile InputRecording (.tactileinput) for InputAnalysis or tactilectl. Report times are not included."
            : "Save the input recording as JSON. It replays without a controller."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseOpenURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, libraryType]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Input Lab recording (.json) or a Tactile InputRecording (.tactileinput)."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = prompt; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
