import Foundation
import Synchronization
import Testing
import TactileCore
@testable import TactileHaptics

func samplePattern() -> HapticPattern {
    HapticPattern(name: "Demo", tracks: [
        HapticPatternTrack(id: "fx", name: "Effects", events: [
            HapticPatternEvent(id: "e1", time: 0, .effect(.click(intensity: 1, frequency: 250), side: .both)),
            HapticPatternEvent(id: "e2", time: 0.1, .effect(.impact(intensity: 0.8), side: .left)),
            HapticPatternEvent(id: "e3", time: 0.2, .effect(.texture(intensity: 0.5, grainRate: 60, duration: 0.2), side: .right)),
        ]),
        HapticPatternTrack(id: "audio", name: "Audio", events: [
            HapticPatternEvent(id: "a1", time: 0.05, .audio(HapticAudioClip(path: "boom.wav", gain: 0.5, trimStart: 0.01, trimEnd: 0.15))),
        ]),
        HapticPatternTrack(id: "rumble", name: "Rumble", events: [
            HapticPatternEvent(id: "r1", time: 0.3, .rumble(Rumble(left: 200, right: 100), duration: 0.1)),
        ]),
        HapticPatternTrack(id: "ctl", name: "Controls", events: [
            HapticPatternEvent(id: "t1", time: 0, .trigger(.right, .weapon(start: 2, end: 6, strength: 8))),
            HapticPatternEvent(id: "l1", time: 0, .lightbar(LightbarColor(red: 0, green: 0, blue: 0), interpolation: .step)),
            HapticPatternEvent(id: "l2", time: 0.1, .lightbar(LightbarColor(red: 255, green: 0, blue: 0), interpolation: .linear)),
        ]),
    ])
}

/// 100 Hz sine at 48 kHz, 0.2 s, stereo with the right channel inverted.
let syntheticLoader: HapticClipLoader = { _ in
    let l = (0..<9600).map { Float(sin(2 * Double.pi * 100 * Double($0) / 48000)) }
    return DecodedAudioClip(sampleRate: 48000, channels: [l, l.map { -$0 }])
}

@Suite struct HapticPatternTests {
    @Test func jsonRoundTrip() throws {
        let p = samplePattern()
        let data = try p.encoded()
        let back = try HapticPattern(data: data)
        #expect(back == p)
        #expect(try back.encoded() == data)  // stable bytes
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""schemaVersion" : 1"#))
        #expect(json.contains(#""type" : "trigger""#))
        #expect(HapticPattern.fileExtension == "tactilepattern")
    }

    @Test func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("demo.\(HapticPattern.fileExtension)")
        try samplePattern().write(to: url)
        #expect(try HapticPattern(contentsOf: url) == samplePattern())
    }

    @Test func rejectsNewerSchemaAndUnknownEvents() {
        #expect(throws: HapticPattern.Failure.unsupportedSchemaVersion(2)) {
            try HapticPattern(data: Data(#"{"schemaVersion":2,"name":"x","tracks":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try HapticPattern(data: Data(#"{"schemaVersion":1,"tracks":[{"events":[{"time":0,"type":"smell"}]}]}"#.utf8))
        }
    }

    @Test func minimalJSONUsesDefaults() throws {
        let p = try HapticPattern(data: Data(#"""
        {"schemaVersion":1,"tracks":[{"name":"t","events":[
          {"time":0.5,"type":"audio","clip":{"path":"a.wav"}},
          {"time":1,"type":"rumble","left":10,"right":20}
        ]}]}
        """#.utf8))
        #expect(p.name == "Untitled")
        guard case let .audio(clip) = p.tracks[0].events[0].action else { Issue.record("not audio"); return }
        #expect(clip.gain == 1 && clip.trimStart == 0 && clip.trimEnd == nil && clip.side == .both)
        guard case let .rumble(r, d) = p.tracks[0].events[1].action else { Issue.record("not rumble"); return }
        #expect(r == Rumble(left: 10, right: 20) && d == 0)
    }

    @Test func durationFromEvents() {
        let p = samplePattern()
        #expect(abs(p.duration - 0.4) < 1e-9)  // texture 0.2+0.2 and rumble 0.3+0.1
    }

    @Test func offlineRenderIsDeterministic() throws {
        let a = try HapticPatternRenderer.renderOffline(samplePattern(), clipLoader: syntheticLoader)
        let b = try HapticPatternRenderer.renderOffline(samplePattern(), clipLoader: syntheticLoader)
        #expect(a == b)
        #expect(a.quantized().left == b.quantized().left)
        #expect(a.sampleRate == 3000)
        #expect(a.frameCount == 1200)  // ends at 0.4 s
        #expect(a.left.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test func eventsLandOnTime() throws {
        let p = HapticPattern(tracks: [HapticPatternTrack(name: "t", events: [
            HapticPatternEvent(time: 0.1, .effect(.click(), side: .left)),
        ])])
        let r = try HapticPatternRenderer.renderOffline(p)
        #expect(r.left[..<300].allSatisfy { $0 == 0 })
        #expect(rms(r.left[300..<336]) > 0.1)
        #expect(r.right.allSatisfy { $0 == 0 })  // left side only
    }

    @Test func mutedTracksAreSilent() throws {
        var p = samplePattern()
        for i in p.tracks.indices { p.tracks[i].isMuted = true }
        let r = try HapticPatternRenderer.renderOffline(p, clipLoader: syntheticLoader)
        #expect(r.frameCount == 0)
        #expect(p.controlTimeline().isEmpty)
    }

    @Test func audioClipIsTrimmedResampledAndGained() throws {
        let p = HapticPattern(tracks: [HapticPatternTrack(name: "a", events: [
            HapticPatternEvent(time: 0, .audio(HapticAudioClip(path: "x", gain: 0.5, trimStart: 0.05, trimEnd: 0.15))),
        ])])
        let r = try HapticPatternRenderer.renderOffline(p, clipLoader: syntheticLoader)
        #expect(abs(r.frameCount - 300) <= 2)  // 0.1 s at 3 kHz
        let level = rms(r.left[30..<270])
        #expect(abs(level - Float(0.5 / 2.0.squareRoot())) < 0.05)
        // Right channel is the inverted source.
        #expect(abs(r.left[100] + r.right[100]) < 1e-5)
        // One-sided clips mix to mono: here the channels cancel.
        var q = p
        q.tracks[0].events[0].action = .audio(HapticAudioClip(path: "x", side: .left))
        let m = try HapticPatternRenderer.renderOffline(q, clipLoader: syntheticLoader)
        #expect(m.left.allSatisfy { abs($0) < 1e-4 } && m.right.allSatisfy { $0 == 0 })
    }

    @Test func missingLoaderThrows() {
        #expect(throws: HapticPattern.Failure.self) { try HapticPatternRenderer.renderOffline(samplePattern()) }
    }

    @Test func rumbleMatchesMixerEmulation() throws {
        let p = HapticPattern(tracks: [HapticPatternTrack(name: "r", events: [
            HapticPatternEvent(time: 0, .rumble(Rumble(left: 255, right: 0), duration: 0.1)),
        ])])
        let r = try HapticPatternRenderer.renderOffline(p)
        #expect(r.frameCount == 300)
        #expect(r.left == r.right)  // heavy motor drives both coils
        #expect(abs(r.left.max()! - 0.8) < 0.01)

        // Held rumble ends at the next rumble event.
        let held = HapticPattern(tracks: [HapticPatternTrack(name: "r", events: [
            HapticPatternEvent(time: 0, .rumble(Rumble(left: 0, right: 255), duration: 0)),
            HapticPatternEvent(time: 0.05, .rumble(.off, duration: 0)),
        ])])
        let h = try HapticPatternRenderer.renderOffline(held)
        #expect(h.frameCount == 150)
        #expect(rms(h.right[0..<150]) > 0.3)
        #expect(h.left.allSatisfy { $0 == 0 })
    }

    @Test func gainScales() throws {
        let full = try HapticPatternRenderer.renderOffline(samplePattern(), clipLoader: syntheticLoader)
        let half = try HapticPatternRenderer.renderOffline(samplePattern(), gain: 0.5, clipLoader: syntheticLoader)
        #expect(rms(half.left[0..<100]) < rms(full.left[0..<100]))
        let silent = try HapticPatternRenderer.renderOffline(samplePattern(), gain: 0, clipLoader: syntheticLoader)
        #expect(silent.left.allSatisfy { $0 == 0 })
    }

    @Test func peaksForWaveform() throws {
        let r = try HapticPatternRenderer.renderOffline(samplePattern(), clipLoader: syntheticLoader)
        let p = r.peaks(bucketCount: 40)
        #expect(p.count == 40)
        #expect(p.allSatisfy { $0.min <= 0 && $0.max >= 0 })
        #expect(p.contains { $0.max > 0.1 })
        #expect(HapticPreview(left: [], right: []).peaks(bucketCount: 3).count == 3)
    }

    @Test func controlTimeline() {
        let c = samplePattern().controlTimeline(lightbarRate: 30)
        guard case .trigger(.right, let e) = c.first?.change else { Issue.record("trigger first"); return }
        #expect(e == (try? TriggerEffect.weapon(start: 2, end: 6, strength: 8)))
        let lights = c.compactMap { ctl -> (Double, LightbarColor)? in
            if case let .lightbar(l) = ctl.change { return (ctl.time, l) } else { return nil }
        }
        #expect(lights.first?.1 == LightbarColor(red: 0, green: 0, blue: 0))
        #expect(lights.last?.0 == 0.1)
        #expect(lights.last?.1 == LightbarColor(red: 255, green: 0, blue: 0))
        #expect(lights.count == 4)  // key, two ramp steps at 1/30 and 2/30 s, key
        for (a, b) in zip(lights, lights.dropFirst()) { #expect(b.1.red >= a.1.red && b.0 > a.0) }
        #expect(samplePattern().lightbarColor(at: 0.05)!.red > 0)
        #expect(samplePattern().lightbarColor(at: 1)?.red == 255)
    }

    @Test func playerStreamsPreviewAndSendsControls() async throws {
        final class Recorder: HapticPatternOutput, @unchecked Sendable {
            let log = Mutex<[String]>([])
            func patternSetTrigger(_ side: TriggerSide, _ effect: TriggerEffect) async { log.withLock { $0.append("trigger \(side)") } }
            func patternSetLightbar(_ color: LightbarColor) async { log.withLock { $0.append("light \(color.red)") } }
        }
        let p = HapticPattern(tracks: [HapticPatternTrack(name: "t", events: [
            HapticPatternEvent(time: 0, .effect(.tone(intensity: 0.5, frequency: 100, duration: 0.05), side: .both)),
            HapticPatternEvent(time: 0.01, .trigger(.left, .feedback(position: 0, strength: 4))),
            HapticPatternEvent(time: 0.02, .lightbar(LightbarColor(red: 9, green: 0, blue: 0), interpolation: .step)),
        ])])
        let mixer = HapticsMixer(streamCapacityFrames: 3000)
        let rec = Recorder()
        let player = try HapticPatternPlayer(pattern: p, mixer: mixer, output: rec)
        #expect(player.preview.frameCount == 150)
        // Nothing consumes the stream here, so the whole preview stays queued.
        let task = Task { await player.play() }
        // Drain the stream on the test's side after the PCM has been queued.
        for _ in 0..<200 where mixer.stream.availableToRead < 300 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mixer.stream.availableToRead == 300)  // 150 stereo frames
        var out = [Int8](repeating: 0, count: 64)
        while mixer.stream.availableToRead > 0 { _ = mixer.render(into: &out) }
        await task.value
        #expect(rec.log.withLock { $0 } == ["trigger left", "light 9"])
    }

    @Test func playerStopClearsStream() async throws {
        let p = HapticPattern(tracks: [HapticPatternTrack(name: "t", events: [
            HapticPatternEvent(time: 0, .effect(.tone(intensity: 0.5, frequency: 100, duration: 2), side: .both)),
        ])])
        let mixer = HapticsMixer()
        let player = try HapticPatternPlayer(pattern: p, mixer: mixer, output: nil)
        player.start()
        #expect(player.isPlaying)
        for _ in 0..<100 where mixer.stream.availableToRead == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mixer.stream.availableToRead > 0)
        player.stop()
        #expect(!player.isPlaying)
        await player.waitUntilFinished()
        var out = [Int8](repeating: 0, count: 64)
        _ = mixer.render(into: &out)  // applies the pending clear
        #expect(mixer.stream.availableToRead == 0)
    }
}
