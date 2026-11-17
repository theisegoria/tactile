import Foundation
import Testing
import Tactile
@testable import Tactile_Lab

@Suite struct InputLabAnalysisTests {
    let analyzer = InputLabAnalyzer()

    private func circle(radius: Double, count: Int = 720, squash: Double = 1) -> [StickPoint] {
        (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi
            return StickPoint(x: cos(a) * radius, y: sin(a) * radius * squash)
        }
    }

    @Test func rawBytesNormaliseAroundCentre() {
        #expect(abs(StickPoint(raw: SIMD2(0, 255)).x + 1) < 1e-9)
        #expect(abs(StickPoint(raw: SIMD2(0, 255)).y - 1) < 1e-9)
        #expect(StickPoint(raw: SIMD2(128, 127)).radius < 0.01)
    }

    @Test func driftOfCentredStickIsTinyWithFloorDeadZone() {
        let resting = (0..<200).map { i in StickPoint(x: i.isMultiple(of: 2) ? 0.004 : -0.004, y: 0) }
        let drift = analyzer.drift(resting: resting)
        #expect(drift.sampleCount == 200)
        #expect(drift.meanRadius < 1e-9)
        #expect(abs(drift.maxRadius - 0.004) < 1e-9)
        #expect(drift.recommendedDeadZone == 0.03)
    }

    @Test func driftingStickGetsDeadZoneCoveringItsRestingOffset() {
        let resting = (0..<300).map { i in StickPoint(x: 0.10 + Double(i % 3) * 0.01, y: -0.02) }
        let drift = analyzer.drift(resting: resting)
        #expect(drift.meanOffset.x > 0.10 && drift.meanOffset.x < 0.12)
        #expect(drift.maxRadius > 0.12)
        #expect(drift.recommendedDeadZone > drift.maxRadius)
        #expect(drift.recommendedDeadZone <= 0.30)
    }

    @Test func emptyRestHasDefaultDeadZone() {
        let drift = analyzer.drift(resting: [])
        #expect(drift.sampleCount == 0)
        #expect(drift.recommendedDeadZone == 0.05)
    }

    @Test func perfectCircleHasFullCoverageAndNoError() {
        let result = analyzer.circularity(circle(radius: 1))
        #expect(result.coverage == 1)
        #expect(result.complete)
        #expect(result.averageErrorPercent < 0.01)
        #expect(abs(result.meanOuterRadius - 1) < 1e-6)
    }

    @Test func undersizedCircleReportsItsError() {
        let result = analyzer.circularity(circle(radius: 0.9))
        #expect(abs(result.averageErrorPercent - 10) < 0.01)
    }

    @Test func halfRotationCoversHalfTheRim() {
        let half = circle(radius: 1).filter { $0.y >= 0 }
        let result = analyzer.circularity(half)
        #expect(result.coverage > 0.45 && result.coverage < 0.55)
        #expect(!result.complete)
    }

    @Test func centreSamplesAreIgnoredByCircularity() {
        let result = analyzer.circularity(circle(radius: 0.2))
        #expect(result.coverage == 0)
        #expect(result.outline.allSatisfy { $0 == nil })
    }

    @Test func triggerRangeAndFullTravel() {
        let full = analyzer.triggerRange([0, 10, 200, 255, 3])
        #expect(full.minimum == 0 && full.maximum == 255)
        #expect(full.fullTravel)
        #expect(full.travel == 1)
        let partial = analyzer.triggerRange([20, 180])
        #expect(!partial.fullTravel)
        #expect(abs(partial.travel - 160.0 / 255) < 1e-9)
    }

    @Test func steadyPollingAt250Hz() {
        let times = (0..<501).map { Double($0) * 0.004 }
        let stats = analyzer.polling(reportTimes: times)
        #expect(stats.intervalCount == 500)
        #expect(abs(stats.measuredHz - 250) < 0.01)
        #expect(abs(stats.p50Ms - 4) < 1e-6)
        #expect(abs(stats.p99Ms - 4) < 1e-6)
        #expect(stats.jitterMs < 1e-6)
        #expect(stats.histogram.map(\.count).reduce(0, +) == 500)
    }

    @Test func jitteryPollingPercentiles() {
        // 98 intervals of 4 ms then two 20 ms stalls.
        var times = [0.0]
        for i in 0..<100 { times.append(times.last! + (i >= 98 ? 0.020 : 0.004)) }
        let stats = analyzer.polling(reportTimes: times.shuffled())
        #expect(stats.intervalCount == 100)
        #expect(abs(stats.p50Ms - 4) < 1e-6)
        #expect(stats.p99Ms > 4)
        #expect(abs(stats.maxMs - 20) < 1e-6)
        #expect(stats.jitterMs > 1)
        #expect(stats.measuredHz < 250)
    }

    @Test func pollingNeedsTwoReports() {
        #expect(analyzer.polling(reportTimes: [1]) == .empty)
        #expect(analyzer.polling(reportTimes: []) == .empty)
    }

    @Test func percentileInterpolates() {
        #expect(InputLabAnalyzer.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(InputLabAnalyzer.percentile([7], 0.99) == 7)
        #expect(InputLabAnalyzer.percentile([], 0.5) == 0)
    }

    @Test func buttonTimingMeasuresHoldsAndRepeats() {
        let cross = Buttons.cross.rawValue, circle = Buttons.circle.rawValue
        let samples = [
            ButtonSample(time: 0.00, buttons: 0),
            ButtonSample(time: 0.10, buttons: cross),
            ButtonSample(time: 0.18, buttons: 0),          // 80 ms hold
            ButtonSample(time: 0.30, buttons: cross),      // 120 ms gap
            ButtonSample(time: 0.50, buttons: cross | circle),
            ButtonSample(time: 0.60, buttons: circle),     // 300 ms hold
            ButtonSample(time: 0.70, buttons: 0),
        ]
        let timings = analyzer.buttonTimings(samples, names: [("Cross", cross), ("Circle", circle), ("Square", Buttons.square.rawValue)])
        #expect(timings.count == 2)
        let x = timings.first { $0.name == "Cross" }
        #expect(x?.presses == 2)
        #expect(abs((x?.shortestHoldMs ?? 0) - 80) < 1e-6)
        #expect(abs((x?.meanHoldMs ?? 0) - 190) < 1e-6)
        #expect(abs((x?.fastestRepeatMs ?? 0) - 120) < 1e-6)
        let o = timings.first { $0.name == "Circle" }
        #expect(o?.presses == 1)
        #expect(o?.fastestRepeatMs == nil)
    }
}
