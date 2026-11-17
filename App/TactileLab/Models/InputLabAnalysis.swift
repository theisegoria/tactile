import Foundation
import Tactile

// Input Lab analysis, backed by the Tactile library's `InputAnalysis`.
//
// The library does the measuring (drift, circularity, trigger travel, button
// edges, interval statistics) on `InputRecording.Sample`s. This file only maps
// its reports onto the view models the Input Lab cards and the health report
// show, and adds the one presentation-only piece the library has no use for:
// the report-interval histogram.

/// A stick position normalised to -1...1 on each axis (x right, y down, as the
/// controller reports it). Used for drawing; analysis runs in the library.
struct StickPoint: Sendable, Hashable, Codable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    /// Maps the controller's 0...255 axis bytes to -1...1 with the library's
    /// normalisation (127.5 is centre).
    init(raw: SIMD2<UInt8>) {
        let p = InputAnalysis.normalized(raw)
        x = p.x; y = p.y
    }
    var radius: Double { (x * x + y * y).squareRoot() }
}

struct DriftResult: Sendable, Hashable, Codable {
    /// Mean resting position (should be 0,0 on a perfect stick).
    var meanOffset: StickPoint
    /// Largest distance from centre seen while resting.
    var maxRadius: Double
    /// Standard deviation of the resting radius (sensor noise).
    var noise: Double
    /// Suggested radial dead zone, 0...1 of full travel (`InputAnalysis.recommendedDeadZone`).
    var recommendedDeadZone: Double
    var sampleCount: Int
    var meanRadius: Double { meanOffset.radius }

    /// No resting samples yet: a conventional 5 % dead zone.
    static let empty = DriftResult(meanOffset: StickPoint(x: 0, y: 0), maxRadius: 0, noise: 0, recommendedDeadZone: 0.05, sampleCount: 0)
}

struct CircularityResult: Sendable, Hashable, Codable {
    static let sectorCount = 72
    /// Largest radius reached in each 5° sector; nil where the stick never
    /// reached the rim threshold.
    var outline: [Double?]
    /// Fraction of sectors that reached the rim threshold (0...1).
    var coverage: Double
    /// RMS deviation of the outline from its own mean radius, in percent of
    /// that mean (`InputAnalysis.CircularityReport.circularityError`): the
    /// shape error, independent of how far the stick reaches.
    var errorPercent: Double
    /// Mean outer radius over visited sectors (1 = full travel).
    var meanOuterRadius: Double
    var complete: Bool { coverage >= 0.95 }
}

struct TriggerRange: Sendable, Hashable, Codable {
    var minimum: UInt8
    var maximum: UInt8
    var sampleCount: Int
    /// The library's verdicts: reached 250 or more, rested at 5 or less.
    var reachesFullPull: Bool
    var returnsToRest: Bool
    /// Fraction of the 0...255 travel actually reached.
    var travel: Double { Double(Int(maximum) - Int(minimum)) / 255 }
    /// True when the trigger both rested near zero and reached near full.
    var fullTravel: Bool { reachesFullPull && returnsToRest }

    static let empty = TriggerRange(minimum: 0, maximum: 0, sampleCount: 0, reachesFullPull: false, returnsToRest: false)
}

struct HistogramBin: Sendable, Hashable, Codable, Identifiable {
    var id: Double { lowerMs }
    var lowerMs: Double
    var upperMs: Double
    var count: Int
    var midMs: Double { (lowerMs + upperMs) / 2 }
}

struct PollingStats: Sendable, Hashable, Codable {
    var intervalCount: Int
    var meanMs: Double
    /// Nearest-rank percentiles, as `IntervalStatistics` computes them.
    var p50Ms: Double
    var p95Ms: Double
    var p99Ms: Double
    var minMs: Double
    var maxMs: Double
    /// Standard deviation of the report interval.
    var jitterMs: Double
    /// Reports per second derived from the mean interval.
    var measuredHz: Double
    var histogram: [HistogramBin]
    static let empty = PollingStats(intervalCount: 0, meanMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, minMs: 0, maxMs: 0, jitterMs: 0, measuredHz: 0, histogram: [])
}

struct ButtonTiming: Sendable, Hashable, Codable, Identifiable {
    var id: String { name }
    var name: String
    /// Presses seen, including one still held at the end.
    var presses: Int
    var meanHoldMs: Double
    var shortestHoldMs: Double
    /// Shortest release-to-press gap (fastest repeat), nil with fewer than two completed presses.
    var fastestRepeatMs: Double?
}

/// Maps the library's `InputAnalysis` reports onto the Input Lab's view models.
struct TactileInputAnalyzer: Sendable {
    /// Without an explicit rest window, samples closer than this to centre count as resting.
    var autoRestRadius = 0.30
    /// Minimum outer radius for a sector to count towards the circularity outline.
    var circularityThreshold = 0.70

    /// Drift of one stick. `restWindow` true means every sample was taken
    /// hands-off, so none is filtered out by distance.
    func drift(_ samples: [InputRecording.Sample], stick: Stick, restWindow: Bool) -> DriftResult {
        guard let report = InputAnalysis.drift(samples, stick: stick, restRadius: restWindow ? .infinity : autoRestRadius) else { return .empty }
        return DriftResult(meanOffset: StickPoint(x: report.meanOffset.x, y: report.meanOffset.y), maxRadius: report.maxRestingRadius,
                           noise: report.noise, recommendedDeadZone: (InputAnalysis.recommendedDeadZone(report) * 1000).rounded() / 1000,
                           sampleCount: report.restingSamples)
    }

    func circularity(_ samples: [InputRecording.Sample], stick: Stick) -> CircularityResult {
        let report = InputAnalysis.circularity(samples, stick: stick, sectors: CircularityResult.sectorCount, minimumRadius: circularityThreshold)
        return CircularityResult(outline: report.sectorRadii.map { $0 >= circularityThreshold ? $0 : nil }, coverage: report.coverage,
                                 errorPercent: report.circularityError * 100, meanOuterRadius: report.meanOuterRadius)
    }

    func triggerRange(_ samples: [InputRecording.Sample], trigger: TriggerSide) -> TriggerRange {
        guard let report = InputAnalysis.triggerTravel(samples, trigger: trigger) else { return .empty }
        return TriggerRange(minimum: report.minimum, maximum: report.maximum, sampleCount: samples.count,
                            reachesFullPull: report.reachesFullPull, returnsToRest: report.returnsToRest)
    }

    /// Statistics of per-report arrival times (seconds). The Input Lab keeps
    /// report times apart from its display-rate frames, so this goes straight
    /// to `IntervalStatistics` rather than through `reportIntervals`.
    func polling(reportTimes: [Double]) -> PollingStats {
        let times = reportTimes.sorted()
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }
        guard let stats = IntervalStatistics(intervals) else { return .empty }
        let ms = intervals.map { $0 * 1000 }.sorted()
        return PollingStats(intervalCount: stats.count, meanMs: stats.mean * 1000, p50Ms: stats.p50 * 1000, p95Ms: stats.p95 * 1000,
                            p99Ms: stats.p99 * 1000, minMs: stats.minimum * 1000, maxMs: stats.maximum * 1000,
                            jitterMs: stats.standardDeviation * 1000, measuredHz: stats.rate, histogram: Self.histogram(ms))
    }

    /// Timing of each named button that has at least one completed press.
    func buttonTimings(_ samples: [InputRecording.Sample], names: [(String, Buttons)]) -> [ButtonTiming] {
        names.compactMap { name, button in
            let report = InputAnalysis.buttonTiming(samples, button: button)
            guard let holds = report.holdDurations else { return nil }
            let gaps = zip(report.presses, report.presses.dropFirst()).compactMap { previous, next in
                previous.releaseTime.map { next.pressTime - $0 }
            }
            return ButtonTiming(name: name, presses: report.presses.count, meanHoldMs: holds.mean * 1000,
                                shortestHoldMs: holds.minimum * 1000, fastestRepeatMs: gaps.min().map { $0 * 1000 })
        }
    }

    /// Fixed-width bins sized to the data (ascending milliseconds in).
    static func histogram(_ sorted: [Double], maxBins: Int = 24) -> [HistogramBin] {
        guard let low = sorted.first, let high = sorted.last else { return [] }
        let span = max(high - low, 0.5)
        let width = max(0.25, (span / Double(maxBins) * 4).rounded(.up) / 4)
        let start = (low / width).rounded(.down) * width
        let count = max(1, Int(((high - start) / width).rounded(.down)) + 1)
        var bins = (0..<count).map { HistogramBin(lowerMs: start + Double($0) * width, upperMs: start + Double($0 + 1) * width, count: 0) }
        for value in sorted { bins[min(count - 1, Int((value - start) / width))].count += 1 }
        return bins
    }
}
