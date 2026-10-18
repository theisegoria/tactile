import Foundation
import Tactile

struct LiveSnapshot: Sendable {
    var input: InputState?
    var imu: CalibratedIMU?
    var reports: UInt64
    var rate: Double
    var raw: [RawReportRow]
    var metrics: [String: Double]
}

actor LiveMonitor {
    private var latest: InputState?
    private var imu: CalibratedIMU?
    private var raw: [RawReportRow] = []
    private var reports: UInt64 = 0
    private var rawSequence: UInt64 = 0
    private var rate = 0.0
    private var rateCount: UInt64 = 0
    private var rateTime = ContinuousClock.now
    private var metrics: [String: Double] = [:]

    func input(_ event: InputEvent) { latest = event.state; imu = event.imu; reports &+= 1 }
    func report(_ report: RawInputReport) {
        rawSequence &+= 1
        raw.append(RawReportRow(id: rawSequence, date: Date(), reportID: report.bytes.first ?? 0, bytes: report.bytes))
        if raw.count > 120 { raw.removeFirst(raw.count - 120) }
    }
    func snapshot(controller: Controller) -> LiveSnapshot {
        let elapsed = (ContinuousClock.now - rateTime).secondsValue
        if elapsed >= 1 {
            rate = Double(reports - rateCount) / elapsed
            rateCount = reports; rateTime = .now
            metrics = metricValues(controller.hapticsMetrics())
        }
        return LiveSnapshot(input: latest, imu: imu, reports: reports, rate: rate, raw: raw, metrics: metrics)
    }

    nonisolated static func stream(for controller: Controller) -> AsyncStream<LiveSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = LiveMonitor()
            let input = Task.detached {
                for await event in await controller.inputEvents() {
                    guard !Task.isCancelled else { break }
                    await monitor.input(event)
                }
                continuation.finish()
            }
            let raw = Task.detached {
                for await report in await controller.rawInputReports() {
                    guard !Task.isCancelled else { break }
                    await monitor.report(report)
                }
            }
            let publisher = Task.detached {
                do {
                    while !Task.isCancelled {
                        continuation.yield(await monitor.snapshot(controller: controller))
                        try await Task.sleep(for: .milliseconds(34))
                    }
                } catch {}
            }
            continuation.onTermination = { _ in input.cancel(); raw.cancel(); publisher.cancel() }
        }
    }
}

enum Simulation {
    static func snapshot(tick: UInt64) -> LiveSnapshot {
        let phase = Double(tick) / 30
        var input = InputState(kind: .bluetoothFull)
        input.leftStick = SIMD2(UInt8(128 + 70 * sin(phase)), UInt8(128 + 70 * cos(phase)))
        input.rightStick = SIMD2(128, 128)
        input.l2 = UInt8(120 + 120 * sin(phase / 2))
        input.r2 = UInt8(120 + 120 * cos(phase / 2))
        input.buttons = tick % 60 < 30 ? [.cross, .paddleLeft, .fnRight] : [.circle, .paddleRight, .fnLeft]
        input.battery = BatteryStatus(percent: 85, charging: .discharging)
        input.touchPoints = [TouchPoint(active: true, id: 1, x: UInt16(960 + 500 * sin(phase)), y: 540), .inactive]
        let calibrated = IMUCalibration.defaults.apply(RawIMU(gyro: SIMD3(1024, 0, -512), accel: SIMD3(0, 0, 8192), timestamp: UInt32(truncatingIfNeeded: tick)))
        let report = RawReportRow(id: tick, date: Date(), reportID: 0x31, bytes: [0x31, UInt8(truncatingIfNeeded: tick), input.l2, input.r2])
        return LiveSnapshot(input: input, imu: calibrated, reports: tick * 8, rate: 240, raw: [report], metrics: [:])
    }
}
