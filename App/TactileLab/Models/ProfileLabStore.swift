import Foundation
import Observation
import Tactile

/// Saved controller profiles, persisted as one JSON file in Application Support.
///
/// Named `LabProfileStore` so it does not clash with the Tactile library's
/// forthcoming `ProfileStore`. The directory is injectable for tests; the app
/// uses `LabProfileStore.shared` (`~/Library/Application Support/Tactile Lab/Profiles`,
/// or `$TACTILE_PROFILES_DIR` when set).
@MainActor @Observable
final class LabProfileStore {
    nonisolated static let fileName = "profiles.json"
    nonisolated static let schemaVersion = 1

    /// On-disk envelope. Import also accepts a bare profile or an array of profiles.
    struct Archive: Codable {
        var schemaVersion = LabProfileStore.schemaVersion
        var activeID: UUID?
        var profiles: [LabProfile]
    }

    let directory: URL
    private(set) var profiles: [LabProfile] = []
    private(set) var activeID: UUID?
    private(set) var lastError: String?

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var activeProfile: LabProfile? { profiles.first { $0.id == activeID } }

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TACTILE_PROFILES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("Tactile Lab", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    // MARK: Persistence

    /// Reloads from disk. A missing file is an empty store, not an error.
    func reload() {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { profiles = []; activeID = nil; return }
            let archive = try Self.decoder.decode(Archive.self, from: Data(contentsOf: fileURL))
            profiles = archive.profiles
            activeID = archive.activeID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            lastError = nil
        } catch {
            lastError = "Could not read profiles: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(Archive(activeID: activeID, profiles: profiles)).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    // MARK: Editing

    @discardableResult
    func add(_ profile: LabProfile) -> LabProfile {
        var copy = profile
        if profiles.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
        copy.name = uniqueName(copy.name)
        copy.createdAt = Date(); copy.modifiedAt = Date()
        profiles.append(copy)
        persist()
        return copy
    }

    func update(_ profile: LabProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var copy = profile
        copy.modifiedAt = Date()
        profiles[index] = copy
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[index].name != trimmed else { return }
        profiles[index].name = uniqueName(trimmed, excluding: id)
        profiles[index].modifiedAt = Date()
        persist()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> LabProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) copy"
        return add(copy)
    }

    func delete(_ ids: Set<UUID>) {
        profiles.removeAll { ids.contains($0.id) }
        if let activeID, ids.contains(activeID) { self.activeID = nil }
        persist()
    }

    func setActive(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    // MARK: Import and export

    /// JSON for the given profiles (all when `ids` is nil), in the archive format.
    func exportData(_ ids: Set<UUID>? = nil) throws -> Data {
        let selected = ids.map { set in profiles.filter { set.contains($0.id) } } ?? profiles
        return try Self.encoder.encode(Archive(activeID: nil, profiles: selected))
    }

    func export(_ ids: Set<UUID>? = nil, to url: URL) throws {
        try exportData(ids).write(to: url, options: .atomic)
    }

    /// Imports profiles from an archive, an array, or a single profile. Imported
    /// profiles get fresh identities and unique names; returns what was added.
    @discardableResult
    func importProfiles(from data: Data) throws -> [LabProfile] {
        let incoming: [LabProfile]
        if let archive = try? Self.decoder.decode(Archive.self, from: data) {
            guard archive.schemaVersion <= Self.schemaVersion else {
                throw LabError.invalid("These profiles come from a newer Tactile Lab (schema \(archive.schemaVersion)).")
            }
            incoming = archive.profiles
        } else if let list = try? Self.decoder.decode([LabProfile].self, from: data) {
            incoming = list
        } else {
            do { incoming = [try Self.decoder.decode(LabProfile.self, from: data)] }
            catch { throw LabError.invalid("This file is not a Tactile Lab profile export.") }
        }
        var added: [LabProfile] = []
        for var profile in incoming {
            profile.id = UUID()
            profile.name = uniqueName(profile.name.isEmpty ? "Imported profile" : profile.name)
            profile.modifiedAt = Date()
            profiles.append(profile)
            added.append(profile)
        }
        persist()
        return added
    }

    @discardableResult
    func importProfiles(from url: URL) throws -> [LabProfile] { try importProfiles(from: Data(contentsOf: url)) }

    // MARK: Applying

    /// Applies a profile through the session's existing output operation and
    /// marks it active. The request lasts the session's test length, after
    /// which outputs return to neutral, like every other Tactile Lab effect.
    /// A simulated session sends nothing to hardware.
    func apply(_ profile: LabProfile, to session: LabSession) {
        guard profile.problems.isEmpty else { session.showError(LabError.invalid(profile.problems.joined(separator: " "))); return }
        session.perform(.output(profile.outputState), name: "Profile: \(profile.name)", settings: profile.summary)
        setActive(profile.id)
    }

    // MARK: Helpers

    /// "Name", or "Name 2", "Name 3"… if already taken.
    func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Profile" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension LabProfileStore {
    /// The app-wide store shared by the Profiles screen and the menu bar item.
    static let shared = LabProfileStore(directory: LabProfileStore.defaultDirectory)
}
