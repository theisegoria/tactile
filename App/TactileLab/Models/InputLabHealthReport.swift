import Foundation
import Tactile

/// Every analysis result the Input Lab shows, computed together.
struct InputLabResults: Sendable, Hashable, Codable {
    var leftDrift: DriftResult
    var rightDrift: DriftResult
    var leftCircularity: CircularityResult
    var rightCircularity: CircularityResult
    var l2: TriggerRange
    var r2: TriggerRange
    var polling: PollingStats
    var buttons: [ButtonTiming]
    /// True when drift came from an explicit "measure rest" window rather than
    /// from samples that happened to be near the centre.
    var driftFromRestWindow: Bool

    /// Runs every analysis over `frames` through the library. `rest` holds the
    /// samples of an explicit "measure rest" window (both sticks hands-off);
    /// without one, drift uses the frames that happen to sit near the centre.
    static func compute(frames: [InputLabFrame], rest: [InputRecording.Sample], reportTimes: [Double],
                        analyzer: TactileInputAnalyzer = TactileInputAnalyzer()) -> InputLabResults {
        let samples = frames.map(\.sample)
        let fromWindow = !rest.isEmpty
        let restSamples = fromWindow ? rest : samples
        return InputLabResults(
            leftDrift: analyzer.drift(restSamples, stick: .left, restWindow: fromWindow),
            rightDrift: analyzer.drift(restSamples, stick: .right, restWindow: fromWindow),
            leftCircularity: analyzer.circularity(samples, stick: .left),
            rightCircularity: analyzer.circularity(samples, stick: .right),
            l2: analyzer.triggerRange(samples, trigger: .left),
            r2: analyzer.triggerRange(samples, trigger: .right),
            polling: analyzer.polling(reportTimes: reportTimes),
            buttons: analyzer.buttonTimings(samples, names: InputLabButtons.all),
            driftFromRestWindow: fromWindow)
    }
}

/// A shareable summary of one controller's health. Exported as JSON and Markdown.
struct InputLabHealthReport: Sendable, Codable {
    static let schemaVersion = 1
    var schemaVersion = InputLabHealthReport.schemaVersion
    var generatedAt = Date()
    var appVersion: String
    var libraryVersion: String
    var deviceName: String
    var deviceID: String?
    var model: String
    var simulated: Bool
    var source: String
    var firmware: String?
    var batteryPercent: Int?
    var batteryState: String?
    var samples: Int
    var results: InputLabResults

    /// Verdict thresholds, kept in one place so the Markdown and UI agree.
    enum Threshold {
        static let driftWarning = 0.08
        static let circularityWarningPercent = 10.0
        static let jitterWarningMs = 4.0
    }

    var findings: [String] {
        var notes: [String] = []
        for (name, drift) in [("Left stick", results.leftDrift), ("Right stick", results.rightDrift)] where drift.sampleCount > 0 {
            if drift.maxRadius > Threshold.driftWarning {
                notes.append("\(name) rests up to \(Self.percent(drift.maxRadius)) from centre; use a dead zone of at least \(Self.percent(drift.recommendedDeadZone)).")
            }
        }
        for (name, circle) in [("Left stick", results.leftCircularity), ("Right stick", results.rightCircularity)] {
            if !circle.complete { notes.append("\(name) circularity incomplete (\(Self.percent(circle.coverage)) of the rim covered); rotate it slowly against the gate.") }
            else if circle.errorPercent > Threshold.circularityWarningPercent { notes.append("\(name) outline deviates \(Self.number(circle.errorPercent, 1))% (RMS) from a circle.") }
        }
        for (name, range) in [("L2", results.l2), ("R2", results.r2)] where range.sampleCount > 0 && !range.fullTravel {
            notes.append("\(name) reached \(range.minimum)–\(range.maximum) of 0–255; press it fully and release to confirm full travel.")
        }
        if results.polling.intervalCount > 10, results.polling.jitterMs > Threshold.jitterWarningMs {
            notes.append("Report interval jitter is \(Self.number(results.polling.jitterMs, 2)) ms; Bluetooth interference or a busy radio is likely.")
        }
        if notes.isEmpty { notes.append("No issues found in the measured range.") }
        return notes
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    func markdown() -> String {
        let r = results
        var text = """
        # Controller health report

        \(deviceName)\(deviceID.map { " · \($0)" } ?? "") · \(model)
        Generated: \(generatedAt.formatted(.iso8601)) · Tactile Lab \(appVersion) · Library \(libraryVersion)
        Source: \(source)\(simulated ? " · SIMULATED — not hardware evidence" : "")
        Firmware: \(firmware ?? "Not available")
        Battery: \(batteryPercent.map { "\($0)%" } ?? "Unknown")\(batteryState.map { " (\($0))" } ?? "")
        Samples: \(samples)

        ## Findings

        """
        for finding in findings { text += "- \(finding)\n" }
        text += """

        ## Sticks

        | | Left | Right |
        |---|---|---|
        | Resting offset (mean) | \(Self.percent(r.leftDrift.meanRadius)) | \(Self.percent(r.rightDrift.meanRadius)) |
        | Resting offset (max) | \(Self.percent(r.leftDrift.maxRadius)) | \(Self.percent(r.rightDrift.maxRadius)) |
        | Noise (σ) | \(Self.percent(r.leftDrift.noise)) | \(Self.percent(r.rightDrift.noise)) |
        | Recommended dead zone | \(Self.percent(r.leftDrift.recommendedDeadZone)) | \(Self.percent(r.rightDrift.recommendedDeadZone)) |
        | Circularity error (RMS) | \(Self.number(r.leftCircularity.errorPercent, 1))% | \(Self.number(r.rightCircularity.errorPercent, 1))% |
        | Outer radius (mean) | \(Self.percent(r.leftCircularity.meanOuterRadius)) | \(Self.percent(r.rightCircularity.meanOuterRadius)) |
        | Rim coverage | \(Self.percent(r.leftCircularity.coverage)) | \(Self.percent(r.rightCircularity.coverage)) |

        Drift measured from \(r.driftFromRestWindow ? "an explicit rest window" : "samples near the centre").

        ## Triggers

        | | Minimum | Maximum | Travel |
        |---|---|---|---|
        | L2 | \(r.l2.minimum) | \(r.l2.maximum) | \(Self.percent(r.l2.travel)) |
        | R2 | \(r.r2.minimum) | \(r.r2.maximum) | \(Self.percent(r.r2.travel)) |

        ## Polling

        \(r.polling.intervalCount) intervals · \(Self.number(r.polling.measuredHz, 1)) Hz · mean \(Self.number(r.polling.meanMs, 2)) ms
        p50 \(Self.number(r.polling.p50Ms, 2)) ms · p95 \(Self.number(r.polling.p95Ms, 2)) ms · p99 \(Self.number(r.polling.p99Ms, 2)) ms · jitter \(Self.number(r.polling.jitterMs, 2)) ms
        Range \(Self.number(r.polling.minMs, 2))–\(Self.number(r.polling.maxMs, 2)) ms

        """
        if !r.buttons.isEmpty {
            text += "\n## Buttons\n\n| Button | Presses | Mean hold | Shortest hold | Fastest repeat |\n|---|---|---|---|---|\n"
            for b in r.buttons {
                text += "| \(b.name) | \(b.presses) | \(Self.number(b.meanHoldMs, 0)) ms | \(Self.number(b.shortestHoldMs, 0)) ms | \(b.fastestRepeatMs.map { "\(Self.number($0, 0)) ms" } ?? "—") |\n"
            }
        }
        text += "\nInput is sampled at the app's display rate (about 30 Hz); report intervals use per-report arrival times. Analysis by the Tactile library's InputAnalysis.\n"
        return text
    }

    static func percent(_ value: Double) -> String { "\(number(value * 100, 1))%" }
    static func number(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
