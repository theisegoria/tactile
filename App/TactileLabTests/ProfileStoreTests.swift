import Foundation
import Testing
import Tactile
@testable import Tactile_Lab

@MainActor
@Suite struct ProfileStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
    }

    private func sample(_ name: String) -> LabProfile {
        var profile = LabProfile(name: name, scope: .game("Astro Bot"))
        profile.lightbar = LightbarColor(red: 255, green: 64, blue: 0)
        profile.playerLEDs = 3
        profile.leftTrigger = .defaults(for: .feedback)
        profile.rightTrigger = .defaults(for: .weapon)
        profile.hapticGain = 1.5
        return profile
    }

    @Test func missingDirectoryIsAnEmptyStore() {
        let store = LabProfileStore(directory: temporaryDirectory())
        #expect(store.profiles.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func addPersistsAndReloads() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LabProfileStore(directory: directory)
        let added = store.add(sample("Racing"))
        store.setActive(added.id)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        let reopened = LabProfileStore(directory: directory)
        #expect(reopened.profiles.count == 1)
        #expect(reopened.profiles[0].name == "Racing")
        #expect(reopened.profiles[0].scope == .game("Astro Bot"))
        #expect(reopened.profiles[0].rightTrigger == LabProfileTrigger.defaults(for: .weapon))
        #expect(reopened.activeID == added.id)
    }

    @Test func renameDuplicateDeleteAndUniqueNames() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LabProfileStore(directory: directory)
        let a = store.add(sample("Shooter"))
        let b = store.add(sample("Shooter"))
        #expect(b.name == "Shooter 2")
        store.rename(b.id, to: "  Sniper  ")
        #expect(store.profiles.first { $0.id == b.id }?.name == "Sniper")
        store.rename(b.id, to: "   ")  // ignored
        #expect(store.profiles.first { $0.id == b.id }?.name == "Sniper")
        store.rename(b.id, to: "shooter")  // case-insensitive clash
        #expect(store.profiles.first { $0.id == b.id }?.name == "shooter 2")
        let copy = store.duplicate(a.id)
        #expect(copy?.name == "Shooter copy")
        #expect(copy?.id != a.id)
        #expect(copy?.leftTrigger == a.leftTrigger)
        store.setActive(a.id)
        store.delete([a.id])
        #expect(store.activeID == nil)
        #expect(store.profiles.count == 2)
        #expect(LabProfileStore(directory: directory).profiles.count == 2)
    }

    @Test func exportImportRoundTripAssignsFreshIdentities() throws {
        let source = LabProfileStore(directory: temporaryDirectory())
        let original = source.add(sample("Horror"))
        let data = try source.exportData()

        let target = LabProfileStore(directory: temporaryDirectory())
        target.add(sample("Horror"))
        let imported = try target.importProfiles(from: data)
        #expect(imported.count == 1)
        #expect(imported[0].id != original.id)
        #expect(imported[0].name == "Horror 2")
        #expect(imported[0].lightbar == original.lightbar)
        #expect(target.profiles.count == 2)
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: target.directory)
    }

    @Test func importAcceptsBareProfileAndArrayAndRejectsJunk() throws {
        let store = LabProfileStore(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        #expect(try store.importProfiles(from: encoder.encode(sample("Solo"))).count == 1)
        #expect(try store.importProfiles(from: encoder.encode([sample("One"), sample("Two")])).count == 2)
        #expect(store.profiles.count == 3)
        #expect(throws: (any Error).self) { try store.importProfiles(from: Data("{\"hello\":1}".utf8)) }
    }

    @Test func exportSelectedOnly() throws {
        let store = LabProfileStore(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let a = store.add(sample("A")); store.add(sample("B"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(LabProfileStore.Archive.self, from: store.exportData([a.id]))
        #expect(archive.profiles.map(\.name) == ["A"])
    }

    @Test func outputStateCarriesLightsAndTriggersButNoRumble() throws {
        let profile = sample("Output")
        let output = profile.outputState
        #expect(output.rumble == nil)
        #expect(output.lightbar == LightbarColor(red: 255, green: 64, blue: 0))
        #expect(output.playerLEDs == .player(3))
        #expect(output.leftTrigger == (try TriggerEffect.feedback(position: 3, strength: 4)))
        #expect(output.rightTrigger == (try TriggerEffect.weapon(start: 3, end: 6, strength: 6)))
        #expect(profile.problems.isEmpty)
    }

    @Test func invalidTriggerParametersAreReported() {
        var profile = sample("Bad")
        profile.rightTrigger = LabProfileTrigger(kind: .weapon, a: 7, b: 3, c: 4)  // end before start
        #expect(profile.rightTrigger.effect == nil)
        #expect(!profile.problems.isEmpty)
    }

    @Test func applyInSimulationRecordsAnOperationAndMarksActive() async {
        let session = LabSession(simulated: true, scenario: "connected")
        await session.start()
        for _ in 0..<200 where !session.canOperate { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.canOperate)
        let store = LabProfileStore(directory: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let profile = store.add(sample("Applied"))
        session.duration = 0.1
        store.apply(profile, to: session)
        #expect(store.activeID == profile.id)
        #expect(session.operations.last?.name == "Profile: Applied")
        #expect(session.operations.last?.simulated == true)
        await session.shutdown()
    }
}
