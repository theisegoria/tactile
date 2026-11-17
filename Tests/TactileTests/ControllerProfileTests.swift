import Foundation
import Synchronization
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tactile-profiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

let sampleProfile = ControllerProfile(id: "racing", name: "Racing", lightbar: LightbarColor(red: 255, green: 64, blue: 0),
                                      playerLEDs: .player(2), playerLEDBrightness: .medium,
                                      leftTrigger: TriggerPreset.brakePedal.spec, rightTrigger: .weapon(start: 2, end: 6, strength: 8),
                                      hapticGain: 0.6, preferredPattern: "engine.tactilepattern")

@Suite struct ControllerProfileTests {
    @Test func jsonRoundTrip() throws {
        let back = try ControllerProfile(data: sampleProfile.encoded())
        #expect(back == sampleProfile)
        let json = String(decoding: try sampleProfile.encoded(), as: UTF8.self)
        #expect(json.contains(#""type" : "slopeFeedback""#))
        // Minimal JSON fills defaults.
        let minimal = try ControllerProfile(data: Data(#"{"name":"Bare"}"#.utf8))
        #expect(minimal.hapticGain == 1 && minimal.lightbar == nil && minimal.schemaVersion == 1)
        #expect(throws: ControllerProfile.Failure.unsupportedSchemaVersion(9)) {
            try ControllerProfile(data: Data(#"{"schemaVersion":9,"name":"x"}"#.utf8))
        }
    }

    @Test func outputStatePatch() throws {
        let s = try sampleProfile.outputState()
        #expect(s.lightbar == LightbarColor(red: 255, green: 64, blue: 0))
        #expect(s.playerLEDs == .player(2))
        #expect(s.playerLEDBrightness == .medium)
        #expect(s.leftTrigger == TriggerPreset.brakePedal.effect)
        #expect(s.rightTrigger == (try TriggerEffect.weapon(start: 2, end: 6, strength: 8)))
        #expect(s.rumble == nil && s.muteLED == nil)
        let empty = try ControllerProfile(name: "Nothing").outputState()
        #expect(empty == OutputState())
        var bad = sampleProfile
        bad.rightTrigger = .weapon(start: 0, end: 1, strength: 8)
        #expect(throws: ControllerProfile.Failure.self) { try bad.outputState() }
        var loud = sampleProfile
        loud.hapticGain = 7
        #expect(loud.clampedGain == 1)
    }

    @Test func applySendsOneReportAndSetsGain() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let connection = fakeConnection(1, send: { r in reports.withLock { $0.append(r) } })
        let controller = Controller(connection: connection, info: device(1), id: "profile")
        try await controller.apply(sampleProfile)
        let last = try #require(reports.withLock { $0.last })
        let base = OutputLayout.bluetoothCommonOffset
        #expect(last[base + OutputLayout.validFlag0] & (OutputLayout.flag0LeftTrigger | OutputLayout.flag0RightTrigger) != 0)
        #expect(Array(last[(base + OutputLayout.rightTrigger)..<(base + OutputLayout.rightTrigger + 11)])
            == (try TriggerEffect.weapon(start: 2, end: 6, strength: 8)).bytes)
        #expect(last[base + OutputLayout.lightbarRed] == 255)
        #expect(last[base + OutputLayout.playerLEDs] & 0x1F == PlayerLEDs.player(2).rawValue)
        await controller.close()
    }

    @Test func storeSavesListsLoadsAndDeletes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(directory: dir.appendingPathComponent("nested"))
        #expect(try store.list().isEmpty)
        try store.save(sampleProfile)
        try store.save(ControllerProfile(id: "a", name: "Arcade"))
        try store.save(ControllerProfile(id: "../evil", name: "zzz"))
        #expect(try store.list().map(\.name) == ["Arcade", "Racing", "zzz"])
        #expect(try store.load(id: "racing") == sampleProfile)
        #expect(try store.load(id: "missing") == nil)
        #expect(store.url(for: "../evil").lastPathComponent == "___evil.tactileprofile")
        try store.delete(id: "a")
        try store.delete(id: "a")  // idempotent
        #expect(try store.list().count == 2)
        // Junk files are skipped.
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("junk.tactileprofile"))
        #expect(try store.list().count == 2)
    }

    @Test func defaultDirectoryIsInApplicationSupport() {
        let d = ProfileStore.defaultDirectory.path
        #expect(d.contains("Application Support"))
        #expect(d.hasSuffix("/Profiles"))
    }
}
