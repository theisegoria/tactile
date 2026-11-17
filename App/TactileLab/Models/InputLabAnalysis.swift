import Foundation

// Pure input analysis for the Input Lab. Everything here is deterministic and
// free of UI or session state so it can be unit-tested with synthetic data.
//
// Seam: the Input Lab talks to `InputLabAnalyzing`, not to these functions
// directly. When the Tactile library ships its own input-analysis functions,
// add a conforming adapter (for example `TactileLibraryAnalyzer`) and pass it
// to `InputLabStore(analyzer:)`; nothing in the views changes.

/// A stick position normalised to -1...1 on each axis (x right, y down, as the
/// controller reports it).
struct StickPoint: Sendable, Hashable, Codable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    /// Maps the controller's 0...255 axis bytes to -1...1 (127.5 is centre).
    init(raw: SIMD2<UInt8>) {
        x = (Double(raw.x) - 127.5) / 127.5
        y = (Double(raw.y) - 127.5) / 127.5
    }
    var radius: Double { (x * x + y * y).squareRoot() }
    /// Angle in radians, 0...2π.
    var angle: Double { let a = atan2(y, x); return a < 0 ? a + 2 * .pi : a }
}

struct DriftResult: Sendable, Hashable, Codable {
    /// Mean resting position (should be 0,0 on a perfect stick).
    var meanOffset: StickPoint
    /// Largest distance from centre seen while resting.
    var maxRadius: Double
    /// Standard deviation of the resting radius (sensor noise).
    var noise: Double
    /// Suggested radial dead zone, 0...1 of full travel.
    var recommendedDeadZone: Double
    var sampleCount: Int
    var meanRadius: Double { meanOffset.radius }
}

struct CircularityResult: Sendable, Hashable, Codable {
    static let sectorCount = 72
    /// Largest radius seen in each 5° sector; nil where the stick never went.
    var outline: [Double?]
    /// Fraction of sectors visited (0...1). A full rotation reaches 1.
    var coverage: Double
    /// Mean absolute deviation of the outline from the ideal unit circle, in percent.
    var averageErrorPercent: Double
    /// Mean outer radius over visited sectors.
    var meanOuterRadius: Double
    var complete: Bool { coverage >= 0.95 }
}

struct TriggerRange: Sendable, Hashable, Codable {
    var minimum: UInt8
    var maximum: UInt8
    var sampleCount: Int
    /// Fraction of the 0...255 travel actually reached.
    var travel: Double { Double(Int(maximum) - Int(minimum)) / 255 }
    /// True when the trigger both rested at (near) zero and reached (near) full.
    var fullTravel: Bool { minimum <= 2 && maximum >= 250 }
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
    var presses: Int
    var meanHoldMs: Double
    var shortestHoldMs: Double
    /// Shortest release-to-press gap (fastest repeat), nil with fewer than two presses.
    var fastestRepeatMs: Double?
}

/// One button state sample: seconds and the pressed-button bitmask.
struct ButtonSample: Sendable, Hashable, Codable {
    var time: Double
    var buttons: UInt32
}

protocol InputLabAnalyzing: Sendable {
    func drift(resting: [StickPoint]) -> DriftResult
    func circularity(_ samples: [StickPoint]) -> CircularityResult
    func triggerRange(_ values: [UInt8]) -> TriggerRange
    func polling(reportTimes: [Double]) -> PollingStats
    func buttonTimings(_ samples: [ButtonSample], names: [(String, UInt32)]) -> [ButtonTiming]
}

/// App-side implementation, used until the Tactile library provides one.
struct InputLabAnalyzer: InputLabAnalyzing {
    /// Stick samples farther than this from centre are not "resting".
    var restThreshold = 0.30
    /// Minimum outer radius for a sample to count towards the circularity outline.
    var circularityThreshold = 0.70

    /// Samples near the centre, used when the caller has no explicit rest window.
    func resting(_ samples: [StickPoint]) -> [StickPoint] { samples.filter { $0.radius < restThreshold } }

    func drift(resting samples: [StickPoint]) -> DriftResult {
        guard !samples.isEmpty else {
            return DriftResult(meanOffset: StickPoint(x: 0, y: 0), maxRadius: 0, noise: 0, recommendedDeadZone: 0.05, sampleCount: 0)
        }
        let n = Double(samples.count)
        let mean = StickPoint(x: samples.map(\.x).reduce(0, +) / n, y: samples.map(\.y).reduce(0, +) / n)
        let radii = samples.map(\.radius)
        let maxRadius = radii.max() ?? 0
        let meanRadius = radii.reduce(0, +) / n
        let noise = (radii.map { ($0 - meanRadius) * ($0 - meanRadius) }.reduce(0, +) / n).squareRoot()
        // Cover the worst resting excursion plus three sigma of noise, with a
        // small floor (one 8-bit step is ~0.008) and a ceiling that keeps the
        // stick usable.
        let deadZone = min(0.30, max(0.03, maxRadius + 3 * noise + 0.01))
        return DriftResult(meanOffset: mean, maxRadius: maxRadius, noise: noise,
                           recommendedDeadZone: (deadZone * 1000).rounded() / 1000, sampleCount: samples.count)
    }

    func circularity(_ samples: [StickPoint]) -> CircularityResult {
        let sectors = CircularityResult.sectorCount
        var outline = [Double?](repeating: nil, count: sectors)
        for point in samples where point.radius >= circularityThreshold {
            let index = min(sectors - 1, Int(point.angle / (2 * .pi) * Double(sectors)))
            outline[index] = max(outline[index] ?? 0, point.radius)
        }
        let visited = outline.compactMap { $0 }
        guard !visited.isEmpty else {
            return CircularityResult(outline: outline, coverage: 0, averageErrorPercent: 0, meanOuterRadius: 0)
        }
        let error = visited.map { abs($0 - 1) }.reduce(0, +) / Double(visited.count) * 100
        return CircularityResult(outline: outline, coverage: Double(visited.count) / Double(sectors),
                                 averageErrorPercent: error, meanOuterRadius: visited.reduce(0, +) / Double(visited.count))
    }

    func triggerRange(_ values: [UInt8]) -> TriggerRange {
        TriggerRange(minimum: values.min() ?? 0, maximum: values.max() ?? 0, sampleCount: values.count)
    }

    func polling(reportTimes: [Double]) -> PollingStats {
        let times = reportTimes.sorted()
        guard times.count >= 2 else { return .empty }
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.filter { $0 > 0 }
        guard !intervals.isEmpty else { return .empty }
        let sorted = intervals.sorted()
        let n = Double(sorted.count)
        let mean = sorted.reduce(0, +) / n
        let jitter = (sorted.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n).squareRoot()
        return PollingStats(intervalCount: sorted.count, meanMs: mean,
                            p50Ms: Self.percentile(sorted, 0.50), p95Ms: Self.percentile(sorted, 0.95), p99Ms: Self.percentile(sorted, 0.99),
                            minMs: sorted.first ?? 0, maxMs: sorted.last ?? 0, jitterMs: jitter,
                            measuredHz: mean > 0 ? 1000 / mean : 0, histogram: Self.histogram(sorted))
    }

    /// Linear-interpolated percentile of an ascending array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let rank = max(0, min(1, p)) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    /// Fixed-width bins sized to the data: 0.5 ms up to 8 ms, wider beyond.
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

    func buttonTimings(_ samples: [ButtonSample], names: [(String, UInt32)]) -> [ButtonTiming] {
        let ordered = samples.sorted { $0.time < $1.time }
        return names.compactMap { name, mask in
            var holds: [Double] = []
            var gaps: [Double] = []
            var pressedAt: Double?
            var releasedAt: Double?
            for sample in ordered {
                let down = sample.buttons & mask != 0
                if down, pressedAt == nil {
                    pressedAt = sample.time
                    if let releasedAt { gaps.append((sample.time - releasedAt) * 1000) }
                } else if !down, let start = pressedAt {
                    holds.append((sample.time - start) * 1000)
                    pressedAt = nil; releasedAt = sample.time
                }
            }
            guard !holds.isEmpty else { return nil }
            return ButtonTiming(name: name, presses: holds.count, meanHoldMs: holds.reduce(0, +) / Double(holds.count),
                                shortestHoldMs: holds.min() ?? 0, fastestRepeatMs: gaps.min())
        }
    }
}
