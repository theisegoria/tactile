import Foundation
import Testing
@testable import Tactile_Lab

@MainActor
@Suite struct SessionTests {
    private func settle(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func deniedPermissionAndNoDeviceNeverEnableOutput() async {
        for scenario in ["denied", "no-device"] {
            let session = LabSession(simulated: true, scenario: scenario)
            await session.start()
            #expect(!session.canOperate)
            #expect(session.devices.isEmpty)
            session.perform(.scan, name: "Must not run", settings: "")
            #expect(session.operations.isEmpty)
            #expect(session.errorMessage != nil)
            await session.shutdown()
        }
    }

    @Test func rapidSelectionClearsReadingsAndKeepsOnlyNewestDevice() async {
        let session = LabSession(simulated: true, scenario: "multiple")
        await session.start()
        #expect(await settle { session.canOperate && session.readings.input != nil })
        for _ in 0..<20 { session.select("simulated-edge"); session.select("simulated-dualsense") }
        #expect(session.readings.input == nil)
        #expect(await settle { session.canOperate && session.readings.input != nil })
        #expect(session.selectedID == "simulated-dualsense")
        #expect(session.readings.input?.buttons.contains(.paddleLeft) == false)
        #expect(session.readings.input?.buttons.contains(.paddleRight) == false)
        await session.shutdown()
        #expect(session.activeOperation == nil)
    }

    @Test func stopAllCancelsOutputAndDoesNotPassGuidedCheck() async {
        let session = LabSession(simulated: true)
        await session.start()
        #expect(await settle { session.canOperate })
        session.duration = 30
        session.perform(.scan, name: "Long simulated scan", settings: "test", guidedID: "microphone")
        #expect(await settle { session.activeOperation != nil })
        let start = ContinuousClock.now
        await session.stopAll()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(session.activeOperation == nil)
        #expect(session.observations.first { $0.id == "microphone" }?.result == .unverified)
        #expect(session.operations.last?.transportResult.contains("Cancelled") == true)
        await session.shutdown()
    }

    @Test func failedOutputIsActionableAndNeverPassesObservation() async {
        let session = LabSession(simulated: true, scenario: "failure")
        await session.start()
        #expect(await settle { session.canOperate })
        session.perform(.scan, name: "Failure", settings: "", guidedID: "microphone")
        #expect(await settle { session.errorMessage != nil })
        #expect(session.operations.last?.transportResult.contains("Failed") == true)
        #expect(session.observations.allSatisfy { $0.result == .unverified })
        await session.shutdown()
    }

    @Test func rapidOperationsCancelOlderJobs() async {
        let session = LabSession(simulated: true)
        await session.start()
        #expect(await settle { session.canOperate })
        session.duration = 0.1
        for index in 0..<15 { session.perform(.scan, name: "Request \(index)", settings: "latest wins") }
        #expect(await settle { session.activeOperation == nil && session.operations.last?.finishedAt != nil })
        #expect(session.operations.last?.name == "Request 14")
        #expect(session.operations.last?.transportResult.contains("Simulated request completed") == true)
        #expect(session.operations.dropLast().allSatisfy { $0.transportResult.contains("Cancelled") })
        await session.shutdown()
    }

    @Test func exportsAreVersionedAndPreserveHumanObservation() async throws {
        let session = LabSession(simulated: true)
        await session.start()
        #expect(await settle { session.canOperate })
        session.observe("input", result: .pass, notes: "Simulation only | two sticks")
        let report = session.report()
        #expect(report.schemaVersion == 1 && report.simulated)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await DiagnosticsService.export(report, to: folder)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionReport.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        #expect(decoded.observations.first?.result == .pass)
        #expect(decoded.observations.first?.simulated == true)
        let markdown = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(markdown.contains("SIMULATED") && markdown.contains("Simulation only \\| two sticks"))
        await session.shutdown()
    }

    @Test func controllerChangeArchivesObservationsWithoutAssigningThemToAnotherDevice() async {
        let session = LabSession(simulated: true, scenario: "multiple")
        await session.start()
        #expect(await settle { session.canOperate })
        session.observe("input", result: .pass, notes: "Edge simulation")
        session.select("simulated-dualsense")
        #expect(await settle { session.canOperate })
        #expect(session.observations.allSatisfy { $0.result == .unverified })
        let saved = session.report().observations.first { $0.notes == "Edge simulation" }
        #expect(saved?.deviceID == "simulated-edge")
        #expect(saved?.result == .pass)
        await session.shutdown()
    }
}
