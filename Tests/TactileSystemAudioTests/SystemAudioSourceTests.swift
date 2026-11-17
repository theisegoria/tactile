import Foundation
import Testing
import TactileHaptics
@testable import TactileSystemAudio

// Never starts capture: ScreenCaptureKit needs a permission prompt and would
// record real system audio.
@Suite struct SystemAudioSourceTests {
    @Test func configurationNormalizesUnsupportedValues() {
        let c = SystemAudioHapticsSource.Configuration(sampleRate: 44100, channelCount: 6)
        #expect(c.sampleRate == 48000)
        #expect(c.channelCount == 2)
        #expect(SystemAudioHapticsSource.Configuration(sampleRate: 16000, channelCount: 1).sampleRate == 16000)
        #expect(SystemAudioHapticsSource.Configuration().target == .allSystemAudio)
    }

    @Test func initDoesNotCapture() async {
        let mixer = HapticsMixer()
        let s = SystemAudioHapticsSource(mixer: mixer, configuration: .init(target: .application(bundleIdentifier: "com.example.game")))
        #expect(!s.isRunning)
        #expect(s.currentLevel == 0)
        #expect(s.droppedFrames == 0)
        s.updateFilter(.game)
        await s.stop()  // no-op when not running
        #expect(mixer.stream.availableToRead == 0)
    }

    @Test func targetIsCodable() throws {
        let t = SystemAudioHapticsSource.Target.application(bundleIdentifier: "com.example.game")
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(SystemAudioHapticsSource.Target.self, from: data) == t)
    }
}
