// Streaming band-limited resampler (windowed-sinc interpolation) from any
// input rate to the controller's 3 kHz haptics rate. Pure Swift, no allocation
// per sample; one instance per channel.

import Foundation

public struct StreamingResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    /// Zero crossings of the sinc on each side (quality/cost trade-off).
    public let halfWidth: Int

    private let step: Double       // input samples per output sample
    private let cutoff: Double     // normalised to input rate (cycles/sample)
    private let radius: Int        // kernel radius in input samples
    private var history: [Float]   // ring of recent input samples
    private var head = 0           // next write index into history
    private var written: Int64 = 0 // total input samples consumed
    private var nextOut: Double    // input-sample position of next output

    public init(inputRate: Double, outputRate: Double = 3000, halfWidth: Int = 12) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.halfWidth = halfWidth
        step = inputRate / outputRate
        // Anti-aliasing: cut at 90% of the lower Nyquist.
        cutoff = 0.45 * min(1.0, outputRate / inputRate)
        radius = max(1, Int((Double(halfWidth) / (2 * cutoff)).rounded(.up)))
        history = [Float](repeating: 0, count: 2 * radius + 2)
        // Output 0 is centred on input 0; it is emitted once `radius` samples of
        // look-ahead have arrived, which is the resampler's latency.
        nextOut = 0
    }

    /// Group delay introduced by the filter, in output samples.
    public var latencyOutputSamples: Double { Double(radius) / step }

    private func sample(at absolute: Int64) -> Float {
        let age = written - 1 - absolute  // 0 = newest
        guard absolute >= 0, age >= 0, age < Int64(history.count) else { return 0 }
        var idx = head - 1 - Int(age)
        if idx < 0 { idx += history.count }
        return history[idx]
    }

    @inline(__always)
    private func kernel(_ x: Double) -> Double {
        // Blackman-windowed sinc with cutoff `cutoff`.
        let r = Double(radius)
        if abs(x) >= r { return 0 }
        let s = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
        let w = 0.42 + 0.5 * cos(.pi * x / r) + 0.08 * cos(2 * .pi * x / r)
        return s * w
    }

    /// Feeds input samples and appends any produced output samples to `out`.
    public mutating func process(_ input: UnsafeBufferPointer<Float>, into out: inout [Float]) {
        for x in input {
            history[head] = x
            head = head + 1 == history.count ? 0 : head + 1
            written += 1
            // Produce every output whose kernel window is fully available.
            while nextOut + Double(radius) <= Double(written - 1) {
                let center = nextOut
                let base = Int64(center.rounded(.down))
                var acc = 0.0
                var k = base - Int64(radius) + 1
                while k <= base + Int64(radius) {
                    acc += Double(sample(at: k)) * kernel(Double(k) - center)
                    k += 1
                }
                out.append(Float(acc))
                nextOut += step
            }
        }
    }

    public mutating func process(_ input: [Float], into out: inout [Float]) {
        input.withUnsafeBufferPointer { process($0, into: &out) }
    }
}
