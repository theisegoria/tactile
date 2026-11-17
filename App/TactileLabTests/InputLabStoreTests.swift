import Foundation
import Testing
import Tactile
@testable import Tactile_Lab

@MainActor
@Suite struct InputLabStoreTests {
    /// A synthetic capture: left stick rests for 1 s, then circles the rim;
    /// triggers sweep fully; Cross is tapped; reports arrive every 4 ms.
    private func syntheticRecording() -> InputLabRecording {
        var frames: [InputLabFrame] = []
        for i in 0..<300 {
            let t = Double(i) / 100
            var left = SIMD2<UInt8>(130, 127)
            if t >= 1 {
                let a = (t - 1) / 2 * 2 * .pi
                left = SIMD2(UInt8(127.5 + 127 * cos(a)), UInt8(127.5 + 127 * sin(a)))
            }
            let sweep = UInt8(min(255, max(0, 255 * (0.5 - 0.5 * cos(t * .pi)))))
            let buttons: UInt32 = (i / 20) % 2 == 1 ? Buttons.cross.rawValue : 0
            frames.append(InputLabFrame(t: t, left: left, right: SIMD2(128, 128), l2: sweep, r2: sweep, buttons: buttons, battery: 75, charging: "discharging"))
        }
        let reports = (0..<750).map { Double($0) * 0.004 }
        return InputLabRecording(deviceName: "Synthetic DualSense", model: "DualSense", simulated: true, frames: frames, reportTimes: reports)
    }

    @Test func recordingRoundTripsThroughJSON() throws {
        let recording = syntheticRecording()
        let decoded = try InputLabRecording.decode(recording.encoded())
        // ISO 8601 keeps whole seconds; everything else must survive exactly.
        #expect(decoded.frames == recording.frames)
        #expect(decoded.reportTimes == recording.reportTimes)
        #expect(decoded.deviceName == recording.deviceName && decoded.simulated == recording.simulated)
        #expect(abs(decoded.createdAt.timeIntervalSince(recording.createdAt)) < 1)
        #expect(abs(decoded.duration - 2.996) < 1e-9)
    }

    @Test func newerSchemaIsRejected() throws {
        var recording = syntheticRecording()
        recording.schemaVersion = InputLabRecording.currentSchema + 1
        #expect(throws: (any Error).self) { try InputLabRecording.decode(recording.encoded()) }
    }

    @Test func instantReplayDrivesTheAnalysis() {
        let store = InputLabStore()
        store.replay(syntheticRecording(), instant: true)
        #expect(store.source == .replay)
        #expect(store.replayProgress == 1)
        #expect(store.frames.count == 300)
        let r = store.results
        #expect(r.leftCircularity.coverage > 0.9)
        #expect(r.leftDrift.sampleCount > 0)
        #expect(r.leftDrift.maxRadius > 0.01)
        #expect(r.l2.maximum >= 250)
        #expect(abs(r.polling.measuredHz - 250) < 0.5)
        #expect(r.buttons.first { $0.name == "Cross" }?.presses ?? 0 >= 5)
        store.goLive()
        #expect(store.source == .live)
        #expect(store.frames.isEmpty)
    }

    @Test func liveIngestIgnoredDuringReplay() {
        let store = InputLabStore()
        store.replay(syntheticRecording(), instant: true)
        var state = InputState(kind: .bluetoothFull)
        state.leftStick = SIMD2(0, 0)
        store.ingest(state, at: 1_000)
        #expect(store.frames.count == 300)
    }

    @Test func liveRecordingCapturesFramesAndReports() {
        var now = 100.0
        let store = InputLabStore(clock: { now })
        store.startRecording()
        for i in 0..<10 {
            var state = InputState(kind: .bluetoothFull)
            state.l2 = UInt8(i * 20)
            store.ingest(state, at: now)
            now += 0.033
        }
        let rows = (1...5).map { RawReportRow(id: UInt64($0), date: Date(timeIntervalSinceReferenceDate: 100 + Double($0) * 0.004), reportID: 0x31, bytes: [0x31]) }
        store.ingestReports(rows)
        store.ingestReports(rows)  // duplicates are ignored
        let device = LabDevice(id: "x", name: "Test", model: "DualSense", transport: "bluetooth", connected: true, simulated: true)
        let recording = store.stopRecording(device: device)
        #expect(recording?.frames.count == 10)
        #expect(recording?.reportTimes.count == 5)
        #expect(recording?.frames.first?.t == 0)
        #expect(recording?.simulated == true)
        #expect(store.reportTimes.count == 5)
        #expect(!store.isRecording)
    }

    @Test func restWindowDrivesDrift() {
        let store = InputLabStore()
        var state = InputState(kind: .bluetoothFull)
        state.leftStick = SIMD2(140, 128)
        store.ingest(state, at: 0)
        store.measureRest(seconds: 1)
        for i in 1...20 { store.ingest(state, at: Double(i) * 0.04) }
        state.leftStick = SIMD2(255, 128)
        store.ingest(state, at: 2)  // closes the window
        #expect(!store.measuringRest)
        #expect(store.results.driftFromRestWindow)
        #expect(store.results.leftDrift.sampleCount == 20)
    }

    @Test func healthReportExportsJSONAndMarkdown() throws {
        let store = InputLabStore()
        store.replay(syntheticRecording(), instant: true)
        let report = InputLabHealthReport(appVersion: "test", libraryVersion: TactileVersion.string, deviceName: "Synthetic DualSense",
                                          deviceID: nil, model: "DualSense", simulated: true, source: "Replayed recording",
                                          firmware: nil, batteryPercent: 75, batteryState: "discharging", samples: store.frames.count, results: store.results)
        let markdown = report.markdown()
        #expect(markdown.contains("# Controller health report"))
        #expect(markdown.contains("Recommended dead zone"))
        #expect(markdown.contains("p99"))
        #expect(markdown.contains("Circularity error (RMS)"))
        #expect(markdown.contains("SIMULATED"))
        #expect(markdown.contains("Battery: 75%"))
        let json = try JSONSerialization.jsonObject(with: report.json()) as? [String: Any]
        #expect(json?["deviceName"] as? String == "Synthetic DualSense")
        #expect(json?["results"] != nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try InputLabStore.write(report, to: folder)
        #expect(FileManager.default.fileExists(atPath: written.appendingPathComponent("health.json").path))
        #expect(FileManager.default.fileExists(atPath: written.appendingPathComponent("health.md").path))
    }

    @Test func findingsFlagDriftAndPartialTriggers() {
        var results = InputLabResults.compute(frames: [], rest: [], reportTimes: [])
        let resting = (0..<10).map { InputLabFrame(t: Double($0) * 0.01, left: SIMD2(148, 128), right: SIMD2(128, 128), l2: 0, r2: 0, buttons: 0).sample }
        results.leftDrift = TactileInputAnalyzer().drift(resting, stick: .left, restWindow: true)
        results.l2 = TriggerRange(minimum: 0, maximum: 200, sampleCount: 10, reachesFullPull: false, returnsToRest: true)
        let report = InputLabHealthReport(appVersion: "t", libraryVersion: "t", deviceName: "d", deviceID: nil, model: "m", simulated: false,
                                          source: "Live controller", firmware: nil, batteryPercent: nil, batteryState: nil, samples: 10, results: results)
        #expect(report.findings.contains { $0.hasPrefix("Left stick rests") })
        #expect(report.findings.contains { $0.hasPrefix("L2 reached") })
    }
}
