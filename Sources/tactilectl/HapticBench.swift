import Foundation
import Synchronization
import Tactile

/// Runs the haptics pump against a sink that completes immediately, while a
/// 48 kHz source streams through the resampler, to measure cadence jitter and
/// CPU without hardware.
enum HapticBench {
    final class NullSink: HapticsReportSink, @unchecked Sendable {
        func submit(_ report: [UInt8], completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    }

    static func run(seconds: Double) async throws {
        let mixer = HapticsMixer()
        let pump = HapticsPump(mixer: mixer, sink: NullSink(), sendWhileIdle: true)
        let input = PCMInput(mixer: mixer, inputRate: 48000)
        pump.start()
        print("pump running for \(seconds) s with a 48 kHz, 150 Hz test tone…")
        let start = Date()
        var phase = 0.0
        var produced = 0
        while Date().timeIntervalSince(start) < seconds {
            // Feed audio at the wall-clock rate, in ~10 ms blocks, like an audio tap.
            let due = Int(Date().timeIntervalSince(start) * 48000) - produced
            produced += due
            let block = (0..<max(due, 0)).map { _ -> Float in
                phase += 2 * .pi * 150 / 48000
                return Float(sin(phase)) * 0.5
            }
            input.feed(interleaved: block, channelCount: 1)
            if Int(Date().timeIntervalSince(start) * 100) % 50 == 0 { mixer.play(.click()) }
            try await Task.sleep(for: .milliseconds(10))
        }
        pump.stop()
        print(pump.metrics())
        print("resampler latency: \(String(format: "%.2f", input.latencyMs)) ms, dropped frames: \(input.droppedFrames)")
    }
}
