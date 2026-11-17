import Foundation
import Testing
import Tactile
@testable import Tactile_Lab

/// The Input Lab's analysis runs through the library's `InputAnalysis`; these
/// check the mapping onto the Lab's view models with byte-valued input.
@Suite struct InputLabAnalysisTests {
    let analyzer = TactileInputAnalyzer()

    private func sample(_ t: Double, left: SIMD2<UInt8> = SIMD2(128, 128), right: SIMD2<UInt8> = SIMD2(128, 128),
                        l2: UInt8 = 0, r2: UInt8 = 0, buttons: Buttons = []) -> InputRecording.Sample {
        InputLabFrame(t: t, left: left, right: right, l2: l2, r2: r2, buttons: buttons.rawValue).sample
    }

    /// Left stick around its rim as bytes, `squash` flattening the y axis.
    private func circle(amplitude: Double = 127, count: Int = 720, squash: Double = 1) -> [InputRecording.Sample] {
        (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi
            let x = UInt8((127.5 + amplitude * cos(a)).rounded()), y = UInt8((127.5 + amplitude * squash * sin(a)).rounded())
            return sample(Double(i) * 0.01, left: SIMD2(x, y))
        }
    }

    @Test func stickPointUsesTheLibraryNormalisation() {
        let raw = SIMD2<UInt8>(0, 255)
        #expect(StickPoint(raw: raw).x == InputAnalysis.normalized(raw).x)
        #expect(abs(StickPoint(raw: raw).y - 1) < 1e-9)
        #expect(StickPoint(raw: SIMD2(128, 127)).radius < 0.01)
    }

    @Test func frameConvertsToALibrarySample() {
        let frame = InputLabFrame(t: 1.5, left: SIMD2(10, 20), right: SIMD2(30, 40), l2: 50, r2: 60,
                                  buttons: Buttons.cross.rawValue, battery: 70, charging: "charging")
        let s = frame.sample
        #expect(s.time == 1.5)
        #expect(s.state.leftStick == SIMD2(10, 20) && s.state.rightStick == SIMD2(30, 40))
        #expect(s.state.l2 == 50 && s.state.r2 == 60)
        #expect(s.state.buttons == .cross)
        #expect(s.state.battery == BatteryStatus(percent: 70, charging: .charging))
        #expect(InputLabFrame(s.state, t: s.time) == frame)
    }

    @Test func centredStickGetsTheLibraryFloorDeadZone() {
        let resting = (0..<200).map { i in sample(Double(i) * 0.01, left: SIMD2(i.isMultiple(of: 2) ? 128 : 127, 128)) }
        let drift = analyzer.drift(resting, stick: .left, restWindow: false)
        #expect(drift.sampleCount == 200)
        #expect(drift.maxRadius < 0.01)
        #expect(drift.recommendedDeadZone == 0.03)
    }

    @Test func driftMatchesTheLibraryReport() throws {
        let resting = (0..<300).map { i in sample(Double(i) * 0.01, left: SIMD2(140 + UInt8(i % 3), 126)) }
        let drift = analyzer.drift(resting, stick: .left, restWindow: true)
        let library = try #require(InputAnalysis.drift(resting, stick: .left, restRadius: .infinity))
        #expect(drift.meanOffset.x == library.meanOffset.x)
        #expect(drift.maxRadius == library.maxRestingRadius)
        #expect(drift.noise == library.noise)
        #expect(abs(drift.recommendedDeadZone - InputAnalysis.recommendedDeadZone(library)) < 0.001)
        #expect(drift.recommendedDeadZone > drift.maxRadius)
    }

    @Test func restWindowKeepsSamplesOutsideTheAutoRadius() {
        // Resting 0.37 from centre: an explicit window counts it, the automatic filter does not.
        let resting = (0..<50).map { i in sample(Double(i) * 0.01, left: SIMD2(175, 128)) }
        #expect(analyzer.drift(resting, stick: .left, restWindow: true).sampleCount == 50)
        #expect(analyzer.drift(resting, stick: .left, restWindow: false) == .empty)
    }

    @Test func emptyRestHasTheDefaultDeadZone() {
        let drift = analyzer.drift([], stick: .right, restWindow: false)
        #expect(drift.sampleCount == 0)
        #expect(drift.recommendedDeadZone == 0.05)
    }

    @Test func fullRimHasFullCoverageAndLittleError() {
        let result = analyzer.circularity(circle(), stick: .left)
        #expect(result.outline.count == CircularityResult.sectorCount)
        #expect(result.coverage == 1)
        #expect(result.complete)
        #expect(result.errorPercent < 1)
        #expect(result.meanOuterRadius > 0.98)
    }

    @Test func shortTravelIsSizeNotShapeError() {
        // A round stick that only reaches 90 %: the library's error is shape only.
        let result = analyzer.circularity(circle(amplitude: 0.9 * 127.5), stick: .left)
        #expect(result.errorPercent < 1)
        #expect(abs(result.meanOuterRadius - 0.9) < 0.01)
    }

    @Test func squashedRimReportsShapeError() {
        let result = analyzer.circularity(circle(squash: 0.75), stick: .left)
        #expect(result.complete)
        #expect(result.errorPercent > 5)
    }

    @Test func halfRotationCoversHalfTheRim() {
        let half = circle().filter { $0.state.leftStick.y >= 128 }
        let result = analyzer.circularity(half, stick: .left)
        #expect(result.coverage > 0.4 && result.coverage < 0.6)
        #expect(!result.complete)
    }

    @Test func centreSamplesAreIgnoredByCircularity() {
        let result = analyzer.circularity(circle(amplitude: 25), stick: .left)
        #expect(result.coverage == 0)
        #expect(result.outline.allSatisfy { $0 == nil })
        #expect(analyzer.circularity(circle(), stick: .right).coverage == 0)
    }

    @Test func triggerTravelUsesTheLibraryVerdicts() {
        let full = analyzer.triggerRange([0, 10, 200, 255, 3].enumerated().map { sample(Double($0), l2: $1) }, trigger: .left)
        #expect(full.minimum == 0 && full.maximum == 255)
        #expect(full.reachesFullPull && full.returnsToRest && full.fullTravel)
        #expect(full.travel == 1)
        let partial = analyzer.triggerRange([20, 180].enumerated().map { sample(Double($0), r2: $1) }, trigger: .right)
        #expect(!partial.fullTravel && !partial.reachesFullPull)
        #expect(abs(partial.travel - 160.0 / 255) < 1e-9)
        #expect(analyzer.triggerRange([], trigger: .left) == .empty)
    }

    @Test func steadyPollingAt250Hz() {
        let stats = analyzer.polling(reportTimes: (0..<501).map { Double($0) * 0.004 })
        #expect(stats.intervalCount == 500)
        #expect(abs(stats.measuredHz - 250) < 0.01)
        #expect(abs(stats.p50Ms - 4) < 1e-6)
        #expect(abs(stats.p99Ms - 4) < 1e-6)
        #expect(stats.jitterMs < 1e-6)
        #expect(stats.histogram.map(\.count).reduce(0, +) == 500)
    }

    @Test func jitteryPollingPercentilesAreNearestRank() {
        // 98 intervals of 4 ms then two 20 ms stalls.
        var times = [0.0]
        for i in 0..<100 { times.append(times.last! + (i >= 98 ? 0.020 : 0.004)) }
        let stats = analyzer.polling(reportTimes: times.shuffled())
        #expect(stats.intervalCount == 100)
        #expect(abs(stats.p50Ms - 4) < 1e-6)
        #expect(abs(stats.p99Ms - 20) < 1e-6)
        #expect(abs(stats.maxMs - 20) < 1e-6)
        #expect(stats.jitterMs > 1)
        #expect(stats.measuredHz < 250)
    }

    @Test func pollingNeedsTwoReports() {
        #expect(analyzer.polling(reportTimes: [1]) == .empty)
        #expect(analyzer.polling(reportTimes: []) == .empty)
    }

    @Test func buttonTimingMeasuresHoldsAndRepeats() {
        let samples = [
            sample(0.00),
            sample(0.10, buttons: .cross),
            sample(0.18),                          // 80 ms hold
            sample(0.30, buttons: .cross),         // 120 ms release-to-press gap
            sample(0.50, buttons: [.cross, .circle]),
            sample(0.60, buttons: .circle),        // 300 ms hold
            sample(0.70),
        ]
        let timings = analyzer.buttonTimings(samples, names: [("Cross", .cross), ("Circle", .circle), ("Square", .square)])
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

    @Test func libraryRecordingRoundTripsThroughTheLabFormat() throws {
        let frames = (0..<20).map { i in
            InputLabFrame(t: Double(i) * 0.004, left: SIMD2(UInt8(100 + i), 128), right: SIMD2(128, 128), l2: UInt8(i * 10), r2: 0, buttons: 0)
        }
        let lab = InputLabRecording(deviceName: "Synthetic", model: "DualSense", simulated: true, frames: frames, reportTimes: frames.map(\.t))
        let library = try InputRecording(data: lab.libraryRecording.encoded())
        #expect(library.samples.count == 20)
        #expect(library.device == "Synthetic")
        let back = InputLabRecording(library)
        #expect(back.frames == frames)
        #expect(back.reportTimes == frames.map(\.t))
        #expect(try InputLabStore.decodeRecording(library.encoded(), pathExtension: InputRecording.fileExtension).frames == frames)
        // Without the extension, the Lab format is tried first, then the library one.
        #expect(try InputLabStore.decodeRecording(library.encoded(), pathExtension: "json").frames.count == 20)
        #expect(try InputLabStore.decodeRecording(lab.encoded(), pathExtension: "json").frames == frames)
    }
}
