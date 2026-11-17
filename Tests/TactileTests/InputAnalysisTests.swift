import Foundation
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport

private func state(left: (UInt8, UInt8) = (128, 128), right: (UInt8, UInt8) = (128, 128), l2: UInt8 = 0, r2: UInt8 = 0,
                   buttons: Buttons = [], sequence: UInt8? = nil) -> InputState {
    var s = InputState(kind: .bluetoothFull)
    s.leftStick = SIMD2(left.0, left.1)
    s.rightStick = SIMD2(right.0, right.1)
    s.l2 = l2
    s.r2 = r2
    s.buttons = buttons
    s.sequence = sequence
    return s
}

private func recording(_ states: [InputState], interval: Double = 0.004) -> InputRecording {
    var r = InputRecording(device: "test", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    for (i, s) in states.enumerated() { r.append(s, at: Double(i) * interval) }
    return r
}

@Suite struct InputAnalysisTests {
    @Test func driftAndDeadZone() throws {
        // Resting at (134, 124) with ±1 noise, plus some full deflections that are ignored.
        var states: [InputState] = []
        for i in 0..<200 { states.append(state(left: (UInt8(134 + i % 2), UInt8(124 - i % 2)))) }
        for _ in 0..<20 { states.append(state(left: (255, 128))) }
        let r = recording(states)
        let d = try #require(InputAnalysis.drift(r.samples, stick: .left))
        #expect(d.restingSamples == 200)
        #expect(abs(d.meanOffset.x - (134.5 - 127.5) / 127.5) < 1e-9)
        #expect(d.meanOffset.y < 0)
        #expect(d.offsetMagnitude > 0.05 && d.offsetMagnitude < 0.07)
        let dz = InputAnalysis.recommendedDeadZone(d)
        #expect(dz > d.maxRestingRadius && dz < 0.12)
        // A centred stick still gets the minimum dead zone.
        let centred = try #require(InputAnalysis.drift(recording([state()]).samples, stick: .right))
        #expect(InputAnalysis.recommendedDeadZone(centred) == 0.03)
        #expect(InputAnalysis.drift(recording([state(left: (255, 255))]).samples, stick: .left) == nil)
    }

    @Test func circularityOfACircleAndASquare() {
        func ring(_ radius: (Double) -> Double) -> InputRecording {
            recording((0..<720).map { i in
                let a = Double(i) / 720 * 2 * .pi
                let r = radius(a)
                let x = UInt8(max(0, min(255, (127.5 + 127.5 * r * cos(a)).rounded())))
                let y = UInt8(max(0, min(255, (127.5 + 127.5 * r * sin(a)).rounded())))
                return state(left: (x, y))
            })
        }
        let circle = InputAnalysis.circularity(ring { _ in 1 }.samples, stick: .left)
        #expect(circle.coverage == 1)
        #expect(circle.circularityError < 0.01)
        #expect(abs(circle.meanOuterRadius - 1) < 0.02)
        // A square gate (radius up to √2 at the corners, clipped by the axis range).
        let square = InputAnalysis.circularity(ring { a in 1 / max(abs(cos(a)), abs(sin(a))) }.samples, stick: .left)
        #expect(square.circularityError > 0.05)
        #expect(square.sectorRadii.count == 36)
        let half = InputAnalysis.circularity(recording([state(left: (255, 128))]).samples, stick: .left)
        #expect(half.coverage == 1.0 / 36)
    }

    @Test func triggerTravel() throws {
        let r = recording([state(r2: 0), state(r2: 128), state(r2: 255), state(r2: 3)])
        let t = try #require(InputAnalysis.triggerTravel(r.samples, trigger: .right))
        #expect(t.minimum == 0 && t.maximum == 255)
        #expect(t.rangeFraction == 1 && t.reachesFullPull && t.returnsToRest)
        let l = try #require(InputAnalysis.triggerTravel(r.samples, trigger: .left))
        #expect(l.maximum == 0 && !l.reachesFullPull)
        #expect(InputAnalysis.triggerTravel([], trigger: .left) == nil)
    }

    @Test func buttonTiming() throws {
        // Press for 3 samples, release 2, press for 1, release, press and hold to the end.
        let pattern: [Bool] = [false, true, true, true, false, false, true, false, true, true]
        let r = recording(pattern.map { state(buttons: $0 ? .cross : []) }, interval: 0.01)
        let t = InputAnalysis.buttonTiming(r.samples, button: .cross)
        #expect(t.presses.count == 3)
        #expect(abs(t.presses[0].pressTime - 0.01) < 1e-9)
        #expect(abs(t.presses[0].duration! - 0.03) < 1e-9)
        #expect(abs(t.presses[1].duration! - 0.01) < 1e-9)
        #expect(t.presses[2].releaseTime == nil)
        let holds = try #require(t.holdDurations)
        #expect(holds.count == 2 && abs(holds.mean - 0.02) < 1e-9)
        let gaps = try #require(t.pressIntervals)
        #expect(gaps.count == 2 && abs(gaps.minimum - 0.02) < 1e-9 && abs(gaps.maximum - 0.05) < 1e-9)
        #expect(InputAnalysis.buttonTiming(r.samples, button: .circle).presses.isEmpty)
    }

    @Test func reportIntervalStatistics() throws {
        // 4 ms reports with one late 12 ms gap.
        var times = (0..<100).map { Double($0) * 0.004 }
        times.append(times.last! + 0.012)
        var r = InputRecording()
        for (i, t) in times.enumerated() { r.append(state(sequence: UInt8(truncatingIfNeeded: i)), at: t) }
        let s = try #require(InputAnalysis.reportIntervals(r.samples))
        #expect(s.count == 100)
        #expect(abs(s.p50 - 0.004) < 1e-9)
        #expect(abs(s.maximum - 0.012) < 1e-9)
        #expect(abs(s.p99 - 0.004) < 1e-9)
        #expect(s.standardDeviation > 0)
        #expect(s.rate > 240 && s.rate < 250)
        #expect(InputAnalysis.missingReports(r.samples) == 0)
        // Sequence 0, 1, 5 → three missing; wraparound 255 → 0 is not a gap.
        let seq = recording([state(sequence: 254), state(sequence: 255), state(sequence: 0), state(sequence: 4)])
        #expect(InputAnalysis.missingReports(seq.samples) == 3)
        #expect(IntervalStatistics([]) == nil)
        #expect(IntervalStatistics([.nan]) == nil)
    }

    @Test func recordingRoundTripAndLookup() throws {
        let r = recording([state(l2: 1), state(l2: 2), state(l2: 3)], interval: 0.5)
        let back = try InputRecording(data: r.encoded())
        #expect(back == r)
        #expect(r.duration == 1)
        #expect(r.state(at: -1) == nil)
        #expect(r.state(at: 0)?.l2 == 1)
        #expect(r.state(at: 0.7)?.l2 == 2)
        #expect(r.state(at: 9)?.l2 == 3)
        var bad = r
        bad.append(state(), at: 0.1)  // goes backwards: dropped
        #expect(bad.samples.count == 3)
    }

    @Test func replayYieldsSamplesInOrder() async {
        let r = recording((0..<5).map { state(l2: UInt8($0)) }, interval: 0.01)
        var got: [UInt8] = []
        for await s in r.replay(speed: 4) { got.append(s.state.l2) }
        #expect(got == [0, 1, 2, 3, 4])
    }

    @Test func recordFromEventStream() async {
        let (stream, cont) = AsyncStream<InputEvent>.makeStream()
        let base = SuspendingClock.now
        for i in 0..<10 {
            cont.yield(InputEvent(state: state(l2: UInt8(i)), imu: nil, raw: [], timestamp: base + .milliseconds(i * 10)))
        }
        cont.finish()
        let rec = await InputRecording.record(from: stream, duration: 0.045)
        #expect(rec.samples.map(\.state.l2) == [0, 1, 2, 3, 4])
        #expect(abs(rec.samples[4].time - 0.04) < 1e-9)
    }
}
