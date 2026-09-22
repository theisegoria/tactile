// The haptics pump: a time-constrained thread that wakes on a fixed
// 10.667 ms grid (measured with mach_absolute_time), renders 32 frames from
// the mixer, frames them as report 0x32 and hands them to a sink.

import Darwin
import Foundation
import Synchronization
public import TactileCore

/// Receives finished 0x32 reports. `submit` is called on the pump thread and
/// must not block; hand the report off (e.g. to a queue) and return. Call
/// `completion` when the set-report finishes so send latency can be measured.
public protocol HapticsReportSink: AnyObject, Sendable {
    func submit(_ report: [UInt8], completion: @escaping @Sendable (_ success: Bool) -> Void)
}

public final class HapticsPump: @unchecked Sendable {
    public let mixer: HapticsMixer
    public let sink: any HapticsReportSink
    /// When true the pump keeps sending silent reports while idle; when false it
    /// stops sending after `idleReportsBeforeSleep` silent reports.
    public var sendWhileIdle: Bool {
        get { sendWhileIdleFlag.load(ordering: .relaxed) }
        set { sendWhileIdleFlag.store(newValue, ordering: .relaxed) }
    }

    /// Only touched by the pump thread; runs never overlap (see `stop`).
    private var builder: HapticsReportBuilder
    private let recorder = MetricsRecorder()
    private let sendWhileIdleFlag: Atomic<Bool>
    private let running = Atomic<Bool>(false)
    /// Identifies the current run. A pump thread keeps going only while this
    /// still equals the generation it was started with, so a thread that
    /// outlives its `stop()` can never resume after a later `start()`.
    private let generation = Atomic<UInt64>(0)
    private let inFlight = Atomic<Int>(0)
    private struct Control {
        var thread: Thread?
        /// Entered when a run starts, left when its thread exits.
        var exited: DispatchGroup?
    }
    private let control = Mutex(Control())
    private let timebase: mach_timebase_info_data_t
    private let periodTicks: UInt64
    private let idleReportsBeforeSleep = 8
    private let maxInFlight = 3
    private let cpuStart = Mutex<(wall: UInt64, cpu: UInt64)>((0, 0))

    public init(mixer: HapticsMixer, sink: any HapticsReportSink, framing: HapticsFraming = .documented,
                sendWhileIdle: Bool = false) {
        self.mixer = mixer
        self.sink = sink
        sendWhileIdleFlag = Atomic(sendWhileIdle)
        builder = HapticsReportBuilder(framing: framing)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
        let periodNs = HapticsFormat.reportPeriodSeconds * 1e9
        periodTicks = UInt64(periodNs * Double(tb.denom) / Double(tb.numer))
    }

    public var isRunning: Bool { running.load(ordering: .acquiring) }

    /// Starts the pump thread. No-op while already running. Safe from any thread.
    public func start() {
        control.withLock { c in
            guard !running.load(ordering: .acquiring) else { return }
            running.store(true, ordering: .releasing)
            let myGen = generation.add(1, ordering: .acquiringAndReleasing).newValue
            recorder.reset()
            cpuStart.withLock { $0 = (0, 0) }
            let exited = DispatchGroup()
            exited.enter()
            let t = Thread { [self] in
                defer { exited.leave() }
                self.run(generation: myGen)
            }
            t.name = "Tactile.HapticsPump"
            t.qualityOfService = .userInteractive
            t.stackSize = 1 << 18
            c.thread = t
            c.exited = exited
            t.start()
        }
    }

    /// Stops the pump and waits (at most about one period) until its thread has
    /// finished its last pass, so the mixer and sink are no longer touched once
    /// this returns. Safe from any thread; when called on the pump thread itself
    /// (e.g. from `submit`) it does not wait, and the thread exits after the
    /// current pass.
    public func stop() {
        let (exited, onPumpThread) = control.withLock { c -> (DispatchGroup?, Bool) in
            if running.load(ordering: .acquiring) {
                running.store(false, ordering: .releasing)
                generation.add(1, ordering: .acquiringAndReleasing)
            }
            let onPump = c.thread.map { $0 === Thread.current } ?? false
            c.thread = nil
            return (c.exited, onPump)
        }
        if let exited, !onPumpThread { exited.wait() }
    }

    public func metrics() -> HapticsMetrics {
        let (wall0, cpu0) = cpuStart.withLock { $0 }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wall = now > wall0 ? now - wall0 : 0
        let cpu = threadCPUNs.load(ordering: .relaxed)
        // Saturate: the pump publishes its CPU time only once per pass.
        let dc = cpu >= cpu0 ? cpu - cpu0 : 0
        let cpuPct = wall > 0 && wall0 > 0 ? Double(dc) / Double(wall) * 100 : 0
        let buffered = Double(mixer.stream.availableToRead / 2) / HapticsFormat.sampleRate * 1000
        return recorder.snapshot(cpuPercent: cpuPct, bufferedMs: buffered)
    }

    private let threadCPUNs = Atomic<UInt64>(0)

    private func toMicros(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1000
    }

    private func setRealtimePolicy() {
        // Time-constraint policy: ~1 ms of computation within each 10.67 ms period.
        let msToTicks = { (ms: Double) -> UInt32 in
            UInt32(ms * 1e6 * Double(self.timebase.denom) / Double(self.timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(periodTicks), computation: msToTicks(1.0), constraint: msToTicks(3.0), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private func isCurrent(_ gen: UInt64) -> Bool { generation.load(ordering: .acquiring) == gen }

    private func run(generation myGen: UInt64) {
        setRealtimePolicy()
        // Publish the CPU baseline before the start time so `metrics()` never
        // pairs a new start with a stale CPU reading.
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        threadCPUNs.store(cpu0, ordering: .relaxed)
        cpuStart.withLock { $0 = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW), cpu0) }
        var samples = [Int8](repeating: 0, count: HapticsFormat.bytesPerReport)
        var deadline = mach_absolute_time() + periodTicks
        var lastWake: UInt64?
        var idleCount = 0
        while isCurrent(myGen) {
            mach_wait_until(deadline)
            // stop() may have been called while we slept: never render or send after it.
            guard isCurrent(myGen) else { break }
            let now = mach_absolute_time()
            let lateness = now > deadline ? toMicros(now - deadline) : 0
            let interval = lastWake.map { toMicros(now - $0) }
            lastWake = now

            let idle = mixer.isIdle
            let underrun = mixer.render(into: &samples)
            idleCount = idle ? idleCount + 1 : 0
            let shouldSend = sendWhileIdle || idleCount <= idleReportsBeforeSleep
            // Underruns are only meaningful while a stream is actually playing.
            recorder.tick(latenessUs: lateness, intervalUs: interval, underrunFrames: idle ? 0 : underrun)

            if shouldSend {
                if inFlight.load(ordering: .acquiring) >= maxInFlight {
                    recorder.dropped()  // never queue stale haptics behind a stalled link
                } else {
                    let report = builder.build(samples: samples)
                    let built = mach_absolute_time()
                    inFlight.add(1, ordering: .acquiringAndReleasing)
                    sink.submit(report) { [self] ok in
                        self.inFlight.subtract(1, ordering: .acquiringAndReleasing)
                        let done = mach_absolute_time()
                        if ok {
                            self.recorder.sent(latencyUs: self.toMicros(done - built))
                        } else {
                            self.recorder.dropped()
                        }
                    }
                }
            }
            threadCPUNs.store(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), ordering: .relaxed)
            // Advance on the fixed grid; if we fell more than a period behind,
            // resynchronise rather than bursting to catch up.
            deadline += periodTicks
            let after = mach_absolute_time()
            if after > deadline + periodTicks { deadline = after + periodTicks }
        }
    }
}
