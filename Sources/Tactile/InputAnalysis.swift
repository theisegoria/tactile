// Input recordings and pure analyses over them: stick drift and dead-zone,
// stick circularity, trigger travel, button timing and report intervals.

public import Foundation
public import TactileCore
import TactileTransport

/// Timestamped input states. Codable (JSON), so recordings can be saved,
/// shared and replayed.
public struct InputRecording: Sendable, Hashable, Codable {
    public static let fileExtension = "tactileinput"
    public static let currentSchemaVersion = 1

    public struct Sample: Sendable, Hashable, Codable {
        /// Seconds since the recording started (report arrival time).
        public var time: Double
        public var state: InputState

        public init(time: Double, state: InputState) {
            self.time = time
            self.state = state
        }
    }

    public var schemaVersion: Int
    public var createdAt: Date
    /// Free-form device description (model, transport, firmware) for reference.
    public var device: String
    public var samples: [Sample]

    public init(device: String = "", createdAt: Date = Date(), samples: [Sample] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.device = device
        self.createdAt = createdAt
        self.samples = samples
    }

    public var duration: Double { samples.last.map { $0.time - (samples.first?.time ?? 0) } ?? 0 }

    /// Appends a sample; times must not go backwards (out-of-order samples are dropped).
    public mutating func append(_ state: InputState, at time: Double) {
        guard time.isFinite, time >= (samples.last?.time ?? -.infinity) else { return }
        samples.append(Sample(time: time, state: state))
    }

    /// The state in effect at `time` (the latest sample at or before it).
    public func state(at time: Double) -> InputState? {
        guard let first = samples.first, time >= first.time else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo].state
    }

    /// Replays samples in real time (scaled by `speed`), yielding each at its
    /// recorded offset. The stream finishes after the last sample or on cancel.
    public func replay(speed: Double = 1) -> AsyncStream<Sample> {
        let samples = self.samples
        let rate = speed.isFinite && speed > 0 ? speed : 1
        return AsyncStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                let t0 = samples.first?.time ?? 0
                for s in samples {
                    let due = start + .nanoseconds(Int64((s.time - t0) / rate * 1e9))
                    try? await clock.sleep(until: due, tolerance: .milliseconds(1))
                    if Task.isCancelled { break }
                    continuation.yield(s)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public init(data: Data) throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self = try d.decode(InputRecording.self, from: data)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported schema version \(schemaVersion)"))
        }
    }
}

/// Which analogue stick.
public enum Stick: String, Sendable, Hashable, Codable, CaseIterable {
    case left, right
}

/// Pure analyses over recorded input. Stick coordinates are normalised to
/// −1…1 per axis with (128, 128) ≈ centre: `(raw − 127.5) / 127.5`, y down as
/// on the wire.
public enum InputAnalysis {
    @inline(__always)
    public static func normalized(_ raw: SIMD2<UInt8>) -> SIMD2<Double> {
        SIMD2((Double(raw.x) - 127.5) / 127.5, (Double(raw.y) - 127.5) / 127.5)
    }

    static func stick(_ s: InputState, _ which: Stick) -> SIMD2<Double> {
        normalized(which == .left ? s.leftStick : s.rightStick)
    }

    // MARK: Drift and dead zone

    public struct DriftReport: Sendable, Hashable {
        /// Mean resting position (normalised); (0, 0) is a perfectly centred stick.
        public var meanOffset: SIMD2<Double>
        /// Distance of the mean resting position from centre.
        public var offsetMagnitude: Double
        /// Largest resting distance from centre seen.
        public var maxRestingRadius: Double
        /// Standard deviation of the resting radius (noise).
        public var noise: Double
        /// How many samples counted as resting.
        public var restingSamples: Int
    }

    /// Resting offset of a stick: samples within `restRadius` of centre are
    /// taken as "hands off". Nil when no sample qualifies.
    public static func drift(_ samples: [InputRecording.Sample], stick which: Stick, restRadius: Double = 0.2) -> DriftReport? {
        let rest = samples.map { stick($0.state, which) }.filter { ($0 * $0).sum().squareRoot() <= restRadius }
        guard !rest.isEmpty else { return nil }
        let mean = rest.reduce(SIMD2<Double>(0, 0), +) / Double(rest.count)
        let radii = rest.map { ($0 * $0).sum().squareRoot() }
        let meanR = radii.reduce(0, +) / Double(radii.count)
        let variance = radii.reduce(0) { $0 + ($1 - meanR) * ($1 - meanR) } / Double(radii.count)
        return DriftReport(meanOffset: mean, offsetMagnitude: (mean * mean).sum().squareRoot(),
                           maxRestingRadius: radii.max() ?? 0, noise: variance.squareRoot(), restingSamples: rest.count)
    }

    /// A radial dead zone (normalised radius) that hides the resting offset
    /// and noise: 1.2 × the largest resting radius plus 0.02, clamped to 0.03…0.3.
    public static func recommendedDeadZone(_ drift: DriftReport) -> Double {
        min(0.3, max(0.03, drift.maxRestingRadius * 1.2 + 0.02))
    }

    // MARK: Circularity

    public struct CircularityReport: Sendable, Hashable {
        /// Largest radius reached in each angular sector (0 where never visited);
        /// sector 0 starts at angle 0 (pointing right) and goes clockwise on screen (y down).
        public var sectorRadii: [Double]
        /// Mean of the visited sectors' outer radius.
        public var meanOuterRadius: Double
        /// RMS deviation of the visited sectors' outer radius from their mean,
        /// relative to the mean (0 = perfect circle).
        public var circularityError: Double
        /// Fraction of sectors whose outer radius reached `minimumRadius`.
        public var coverage: Double
    }

    /// Outer-edge shape from a recording where the user rotated the stick
    /// around its rim. `sectors` ≥ 4.
    public static func circularity(_ samples: [InputRecording.Sample], stick which: Stick, sectors: Int = 36,
                                   minimumRadius: Double = 0.5) -> CircularityReport {
        let n = max(4, sectors)
        var outer = [Double](repeating: 0, count: n)
        for s in samples {
            let p = stick(s.state, which)
            let r = (p * p).sum().squareRoot()
            guard r > 0 else { continue }
            var a = atan2(p.y, p.x)
            if a < 0 { a += 2 * .pi }
            let k = min(n - 1, Int(a / (2 * .pi) * Double(n)))
            outer[k] = max(outer[k], r)
        }
        let visited = outer.filter { $0 >= minimumRadius }
        let mean = visited.isEmpty ? 0 : visited.reduce(0, +) / Double(visited.count)
        let rms = visited.isEmpty || mean == 0 ? 0
            : (visited.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(visited.count)).squareRoot() / mean
        return CircularityReport(sectorRadii: outer, meanOuterRadius: mean, circularityError: rms,
                                 coverage: Double(visited.count) / Double(n))
    }

    // MARK: Triggers

    public struct TriggerTravelReport: Sendable, Hashable {
        public var minimum: UInt8
        public var maximum: UInt8
        /// (max − min) / 255.
        public var rangeFraction: Double
        /// True when the trigger reached 250 or more (essentially fully pulled).
        public var reachesFullPull: Bool
        /// True when the trigger rested at 5 or less (essentially released).
        public var returnsToRest: Bool
    }

    public static func triggerTravel(_ samples: [InputRecording.Sample], trigger: TriggerSide) -> TriggerTravelReport? {
        let values = samples.map { trigger == .left ? $0.state.l2 : $0.state.r2 }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return TriggerTravelReport(minimum: lo, maximum: hi, rangeFraction: Double(hi - lo) / 255,
                                   reachesFullPull: hi >= 250, returnsToRest: lo <= 5)
    }

    // MARK: Buttons

    public struct ButtonPress: Sendable, Hashable {
        public var pressTime: Double
        /// Nil when still held at the end of the recording.
        public var releaseTime: Double?
        public var duration: Double? { releaseTime.map { $0 - pressTime } }
    }

    public struct ButtonTimingReport: Sendable, Hashable {
        public var presses: [ButtonPress]
        /// Statistics of completed hold durations (seconds), nil with none.
        public var holdDurations: IntervalStatistics?
        /// Statistics of time between successive presses (seconds), nil with < 2.
        public var pressIntervals: IntervalStatistics?
    }

    /// Press/release edges of `button` (any of its bits counts as pressed).
    public static func buttonTiming(_ samples: [InputRecording.Sample], button: Buttons) -> ButtonTimingReport {
        var presses: [ButtonPress] = []
        var down = false
        for s in samples {
            let now = !s.state.buttons.isDisjoint(with: button)
            if now, !down {
                presses.append(ButtonPress(pressTime: s.time, releaseTime: nil))
            } else if !now, down, !presses.isEmpty {
                presses[presses.count - 1].releaseTime = s.time
            }
            down = now
        }
        let holds = presses.compactMap(\.duration)
        let starts = presses.map(\.pressTime)
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        return ButtonTimingReport(presses: presses, holdDurations: IntervalStatistics(holds),
                                  pressIntervals: IntervalStatistics(gaps))
    }

    // MARK: Report intervals

    /// Time between successive samples.
    public static func reportIntervals(_ samples: [InputRecording.Sample]) -> IntervalStatistics? {
        let t = samples.map(\.time)
        return IntervalStatistics(zip(t, t.dropFirst()).map { $1 - $0 })
    }

    /// Reports lost according to the 8-bit sequence counter (when the layout
    /// carries one): the sum of gaps beyond 1, modulo 256.
    public static func missingReports(_ samples: [InputRecording.Sample]) -> Int {
        var missing = 0
        var previous: UInt8?
        for s in samples {
            guard let seq = s.state.sequence else { continue }
            if let p = previous {
                let gap = Int(seq &- p)
                if gap > 1 { missing += gap - 1 }
            }
            previous = seq
        }
        return missing
    }
}

/// Summary statistics of a set of durations (seconds).
public struct IntervalStatistics: Sendable, Hashable {
    public var count: Int
    public var mean: Double
    /// Standard deviation (jitter).
    public var standardDeviation: Double
    public var minimum: Double
    public var maximum: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double
    /// 1 / mean (e.g. reports per second), 0 when the mean is 0.
    public var rate: Double { mean > 0 ? 1 / mean : 0 }

    /// Nil for an empty input. Non-finite values are ignored.
    public init?(_ values: [Double]) {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        count = v.count
        mean = v.reduce(0, +) / Double(v.count)
        let m = mean
        standardDeviation = (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
        minimum = v.first!
        maximum = v.last!
        /// Nearest-rank percentile.
        func pct(_ p: Double) -> Double { v[min(v.count - 1, max(0, Int((p / 100 * Double(v.count)).rounded(.up)) - 1))] }
        p50 = pct(50)
        p95 = pct(95)
        p99 = pct(99)
    }
}

// MARK: Recording from a controller

extension InputRecording {
    /// Records input events until `duration` seconds have passed (measured
    /// from the first event's arrival), `maxSamples` is reached, the stream
    /// ends or the task is cancelled.
    public static func record(from events: AsyncStream<InputEvent>, duration: Double,
                              maxSamples: Int = 1_000_000, device: String = "") async -> InputRecording {
        var rec = InputRecording(device: device)
        var start: SuspendingClock.Instant?
        for await e in events {
            if Task.isCancelled { break }
            let t0 = start ?? e.timestamp
            start = t0
            let d = e.timestamp - t0
            let t = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
            if t > duration { break }
            rec.append(e.state, at: t)
            if rec.samples.count >= maxSamples { break }
        }
        return rec
    }
}

extension Controller {
    /// Records this controller's input for `duration` seconds.
    public func recordInput(duration: Double, maxSamples: Int = 1_000_000) async -> InputRecording {
        await InputRecording.record(from: inputEvents(), duration: duration, maxSamples: maxSamples, device: description)
    }
}
