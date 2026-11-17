import Foundation
import Testing
import Tactile
@testable import Tactile_Lab

@Suite struct ComposerPatternTests {
    private func reload(_ doc: ComposerDocument) throws -> ComposerDocument {
        var notes: [String] = []
        return try ComposerDocument.load(doc.patternData(), clipBase: nil, notes: &notes)
    }

    @Test func savedFileIsALibraryPattern() throws {
        let data = try ComposerDocument.example.patternData()
        let pattern = try HapticPattern(data: data)
        #expect(pattern.schemaVersion == HapticPattern.currentSchemaVersion)
        #expect(pattern.tracks.map(\.id) == ComposerTrack.Kind.allCases.map(\.rawValue))
        #expect(pattern.name == ComposerDocument.example.name)
    }

    @Test func exampleRoundTripsToTheSamePattern() throws {
        let example = ComposerDocument.example
        let once = example.pattern
        let twice = try reload(example).pattern
        for (a, b) in zip(once.tracks, twice.tracks) where a != b {
            Issue.record("track \(a.id):\n\(a.events.map { "\($0.id) \($0.time) \($0.action)" })\nvs\n\(b.events.map { "\($0.id) \($0.time) \($0.action)" })")
        }
        #expect(once == twice)
        let thrice = try reload(reload(example)).pattern
        #expect(twice == thrice)
    }

    @Test func repeatingClickExpandsAndRegroups() throws {
        var doc = ComposerDocument(name: "Repeat")
        let click = ComposerEvent.Parametric(kind: .click, intensity: 0.8, frequency: 250, repeatInterval: 0.1)
        doc.tracks[0].events = [ComposerEvent(start: 0.5, duration: 0.4, content: .parametric(click))]
        let effects = doc.pattern.tracks[0].events
        #expect(effects.count == 4)
        #expect(effects.map(\.time).enumerated().allSatisfy { abs($0.element - (0.5 + Double($0.offset) * 0.1)) < 1e-9 })
        let back = try reload(doc)
        #expect(back.tracks[0].events.count == 1)
        guard case .parametric(let p) = back.tracks[0].events[0].content else { Issue.record("not parametric"); return }
        #expect(abs(p.repeatInterval - 0.1) < 1e-9)
        #expect(back.tracks[0].events[0].id == doc.tracks[0].events[0].id)
    }

    @Test func triggerSpansBecomeChangesWithOffAtTheEnd() throws {
        var doc = ComposerDocument(name: "Triggers")
        let weapon = TriggerDesign(spec: TriggerPreset.weaponTrigger.spec)
        doc.tracks[2].events = [ComposerEvent(start: 0.2, duration: 1, content: .trigger(.init(side: .both, design: weapon)))]
        let changes = doc.pattern.tracks[2].events
        #expect(changes.count == 4)  // weapon and off, on each side
        #expect(changes.contains { $0.time == 0.2 && $0.action == .trigger(.left, TriggerPreset.weaponTrigger.spec) })
        #expect(changes.contains { abs($0.time - 1.2) < 1e-9 && $0.action == .trigger(.right, .off) })
        let back = try reload(doc)
        #expect(back.tracks[2].events.count == 1)
        guard case .trigger(let change) = back.tracks[2].events[0].content else { Issue.record("not a trigger"); return }
        #expect(change.side == .both)
        #expect(change.design.spec == TriggerPreset.weaponTrigger.spec)
        #expect(abs(back.tracks[2].events[0].duration - 1) < 1e-9)
    }

    @Test func lightbarFadeRoundTrips() throws {
        var doc = ComposerDocument(name: "Fade")
        doc.tracks[3].events = [
            ComposerEvent(start: 0, duration: 1, content: .lightbar(.init(red: 0, green: 0, blue: 255))),
            ComposerEvent(start: 1, duration: 1, content: .lightbar(.init(red: 255, green: 0, blue: 0, fade: 0.25))),
        ]
        let keys = doc.pattern.tracks[3].events
        #expect(keys.count == 3)
        #expect(keys.last?.action == .lightbar(LightbarColor(red: 255, green: 0, blue: 0), interpolation: .linear))
        let back = try reload(doc)
        #expect(back.tracks[3].events.count == 2)
        guard case .lightbar(let key) = back.tracks[3].events[1].content else { Issue.record("not a key"); return }
        #expect(abs(key.fade - 0.25) < 1e-9)
        #expect(back.pattern == doc.pattern)
    }

    @Test func earlierAppFilesStillOpen() throws {
        let example = ComposerDocument.example
        let legacy = try example.legacyEncoded()
        var notes: [String] = []
        let doc = try ComposerDocument.load(legacy, clipBase: nil, notes: &notes)
        #expect(doc == example)
        #expect(!notes.isEmpty)
    }

    @Test func previewComesFromTheLibraryRenderer() throws {
        let doc = ComposerDocument.example
        let mix = ComposerMix.render(doc)
        let preview = try HapticPatternRenderer.renderOffline(doc.pattern)
        #expect(mix.left == preview.left)
        #expect(mix.right == preview.right)
        #expect(!mix.isSilent)
    }

    @Test func newerSchemaIsRejected() {
        let json = #"{"schemaVersion": 99, "name": "Future", "tracks": []}"#
        var notes: [String] = []
        #expect(throws: (any Error).self) { try ComposerDocument.load(Data(json.utf8), clipBase: nil, notes: &notes) }
    }
}
