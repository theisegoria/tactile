// Latency and jitter accounting for the haptics pump.

import Synchronization

/// A snapshot of pump statistics. Times are in microseconds.
public struct HapticsMetrics: Sendable, CustomStringConvertible {
    public var reportsBuilt: Int = 0
    public var reportsSent: Int = 0
    public var reportsDropped: Int = 0
    /// Ticks where the stream had fewer than 32 frames (filled with silence).
    public var underrunTicks: Int = 0
    public var underrunFrames: Int = 0
    /// Wake-up lateness relative to the ideal 10.667 ms grid.
    public var wakeLatenessMeanUs: Double = 0
    public var wakeLatenessP99Us: Double = 0
    public var wakeLatenessMaxUs: Double = 0
    /// Interval between successive ticks, and its standard deviation (jitter).
    public var tickIntervalMeanUs: Double = 0
    public var tickIntervalStdDevUs: Double = 0
    /// Time from building a report to its set-report call completing.
    public var sendLatencyMeanUs: Double = 0
    public var sendLatencyP99Us: Double = 0
    public var sendLatencyMaxUs: Double = 0
    /// CPU time consumed by the pump thread, as a percentage of one core.
    public var pumpCPUPercent: Double = 0
    /// Buffered stream audio at snapshot time, in milliseconds.
    public var bufferedMs: Double = 0

    public var description: String {
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        return """
        reports built=\(reportsBuilt) sent=\(reportsSent) dropped=\(reportsDropped)
        underruns ticks=\(underrunTicks) frames=\(underrunFrames)
        wake lateness µs mean=\(f(wakeLatenessMeanUs)) p99=\(f(wakeLatenessP99Us)) max=\(f(wakeLatenessMaxUs))
        tick interval µs mean=\(f(tickIntervalMeanUs)) σ=\(f(tickIntervalStdDevUs))
        send latency µs mean=\(f(sendLatencyMeanUs)) p99=\(f(sendLatencyP99Us)) max=\(f(sendLatencyMaxUs))
        pump CPU=\(f(pumpCPUPercent))% buffered=\(f(bufferedMs)) ms
        """
    }
}

/// Fixed-size reservoir of recent samples for percentile estimates.
struct Reservoir: Sendable {
    private var values: [Double]
    private var index = 0
    private var filled = 0
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var sumSq = 0.0
    private(set) var max = 0.0

    init(size: Int = 2048) { values = [Double](repeating: 0, count: size) }

    mutating func add(_ v: Double) {
        values[index] = v
        index = (index + 1) % values.count
        filled = Swift.min(filled + 1, values.count)
        count += 1
        sum += v
        sumSq += v * v
        if v > max { max = v }
    }

    var mean: Double { count == 0 ? 0 : sum / Double(count) }
    var stdDev: Double {
        guard count > 1 else { return 0 }
        let m = mean
        return (Swift.max(0, sumSq / Double(count) - m * m)).squareRoot()
    }

    func percentile(_ p: Double) -> Double {
        guard filled > 0 else { return 0 }
        let sorted = values.prefix(filled).sorted()
        let i = Swift.min(filled - 1, Int((p * Double(filled - 1)).rounded()))
        return sorted[i]
    }
}

final class MetricsRecorder: Sendable {
    private struct State: Sendable {
        var m = HapticsMetrics()
        var lateness = Reservoir()
        var interval = Reservoir()
        var send = Reservoir()
    }
    private let state = Mutex(State())

    func tick(latenessUs: Double, intervalUs: Double?, underrunFrames: Int) {
        state.withLock { s in
            s.m.reportsBuilt += 1
            s.lateness.add(latenessUs)
            if let i = intervalUs { s.interval.add(i) }
            if underrunFrames > 0 {
                s.m.underrunTicks += 1
                s.m.underrunFrames += underrunFrames
            }
        }
    }

    func sent(latencyUs: Double) {
        state.withLock { s in
            s.m.reportsSent += 1
            s.send.add(latencyUs)
        }
    }

    func dropped() { state.withLock { $0.m.reportsDropped += 1 } }

    func snapshot(cpuPercent: Double, bufferedMs: Double) -> HapticsMetrics {
        state.withLock { s in
            var m = s.m
            m.wakeLatenessMeanUs = s.lateness.mean
            m.wakeLatenessP99Us = s.lateness.percentile(0.99)
            m.wakeLatenessMaxUs = s.lateness.max
            m.tickIntervalMeanUs = s.interval.mean
            m.tickIntervalStdDevUs = s.interval.stdDev
            m.sendLatencyMeanUs = s.send.mean
            m.sendLatencyP99Us = s.send.percentile(0.99)
            m.sendLatencyMaxUs = s.send.max
            m.pumpCPUPercent = cpuPercent
            m.bufferedMs = bufferedMs
            return m
        }
    }

    func reset() { state.withLock { $0 = State() } }
}
