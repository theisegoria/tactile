import Foundation
import Testing
import Tactile
import TactileSystemAudio
@testable import Tactile_Lab

@MainActor
@Suite struct SystemAudioTests {
    @Test func presetsMatchTheLibrarySettings() {
        #expect(SystemAudioPreset.matching(.music) == .music)
        #expect(SystemAudioPreset.matching(.game) == .game)
        #expect(SystemAudioPreset.matching(.passthrough) == .passthrough)
        var custom = HapticFilterSettings.music
        custom.makeupGainDB += 3
        #expect(SystemAudioPreset.matching(custom) == .custom)
    }

    @Test func simulationNeverStartsCaptureAndStopAllEndsIt() async {
        let session = LabSession(simulated: true)
        await session.start()
        for _ in 0..<200 where !session.canOperate { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.canOperate)
        let monitor = SystemAudioMonitor()
        session.duration = 30
        session.perform(.systemAudio(SystemAudioRequest(target: .allSystemAudio, filter: .music, monitor: monitor)),
                        name: SystemAudioHapticsCard.operationName, settings: "test")
        for _ in 0..<200 where session.activeOperation == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.activeOperation == SystemAudioHapticsCard.operationName)
        #expect(!monitor.isAttached)
        await session.stopAll()
        #expect(session.activeOperation == nil)
        #expect(!monitor.isAttached)
        #expect(session.operations.last?.simulated == true)
        await session.shutdown()
    }
}
