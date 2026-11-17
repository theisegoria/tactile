import Foundation
import Observation
import Tactile

/// Saved controller profiles, stored through the Tactile library's
/// `ProfileStore`: one `<id>.tactileprofile` file per profile, readable by
/// `ControllerProfile`, the C ABI and the bindings. The app-only fields
/// (scope, mute LED, timestamps), the list order and the active profile live
/// beside them in `lab-profiles.json`.
///
/// Tactile Lab 1.x kept everything in one `profiles.json`; it is migrated on
/// first load and renamed `profiles.json.migrated`, never deleted. The
/// directory is injectable for tests; the app uses `LabProfileStore.shared`
/// (`~/Library/Application Support/Tactile Lab/Profiles`, or
/// `$TACTILE_PROFILES_DIR` when set).
@MainActor @Observable
final class LabProfileStore {
    nonisolated static let metadataFileName = "lab-profiles.json"
    nonisolated static let legacyFileName = "profiles.json"
    /// Schema of the export archive (unchanged from 1.x, so older Labs can import it).
    nonisolated static let schemaVersion = 1
    nonisolated static let metadataSchemaVersion = 1

    /// Export envelope. Import also accepts a bare profile, an array of
    /// profiles, or a library `.tactileprofile` file.
    struct Archive: Codable {
        var schemaVersion = LabProfileStore.schemaVersion
        var activeID: String?
        var profiles: [LabProfile]
    }

    /// `lab-profiles.json`: what the library format has no place for.
    struct Metadata: Codable {
        var schemaVersion = LabProfileStore.metadataSchemaVersion
        var activeID: String?
        var order: [String] = []
        var extras: [String: LabProfileExtras] = [:]
    }

    let directory: URL
    /// The library store that owns the profile files.
    let library: ProfileStore
    private(set) var profiles: [LabProfile] = []
    private(set) var activeID: String?
    private(set) var lastError: String?

    var metadataURL: URL { directory.appendingPathComponent(Self.metadataFileName) }
    var legacyURL: URL { directory.appendingPathComponent(Self.legacyFileName) }
    /// What "Show in Finder" reveals: the profiles folder.
    var fileURL: URL { directory }
    var activeProfile: LabProfile? { profiles.first { $0.id == activeID } }
    /// The master gain every haptic is sent with: the active profile's, else unity.
    var activeHapticGain: Float { activeProfile?.controllerProfile.clampedGain ?? 1 }

    init(directory: URL) {
        self.directory = directory
        library = ProfileStore(directory: directory)
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

    /// Reloads from disk, migrating a 1.x `profiles.json` first. A missing
    /// folder is an empty store, not an error.
    func reload() {
        do {
            try migrateLegacyArchive()
            let metadata = try readMetadata()
            let stored = try library.list()
            let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Saved order first, then any profile added outside the Lab (library order: by name).
            let ordered = metadata.order.compactMap { byID[$0] } + stored.filter { !metadata.order.contains($0.id) }
            profiles = ordered.map { LabProfile($0, extras: metadata.extras[$0.id]) }
            activeID = metadata.activeID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            lastError = nil
        } catch {
            lastError = "Could not read profiles: \(error.localizedDescription)"
        }
    }

    /// Moves a Tactile Lab 1.x `profiles.json` into library files once. The
    /// old file is renamed, not deleted, so a 1.x build's data stays recoverable.
    private func migrateLegacyArchive() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: metadataURL.path) else { return }
        let archive = try Self.decoder.decode(Archive.self, from: Data(contentsOf: legacyURL))
        var metadata = Metadata(activeID: archive.activeID)
        for var profile in archive.profiles {
            // 1.x stored a 0–4 gain that was never applied; the library's master gain is 0–1.
            profile.hapticGain = profile.hapticGain.isFinite ? min(max(profile.hapticGain, 0), 1) : 1
            try library.save(profile.controllerProfile)
            metadata.order.append(profile.id)
            metadata.extras[profile.id] = profile.extras
        }
        try writeMetadata(metadata)
        let backup = directory.appendingPathComponent(Self.legacyFileName + ".migrated")
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        try fm.moveItem(at: legacyURL, to: backup)
    }

    private func readMetadata() throws -> Metadata {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return Metadata() }
        let metadata = try Self.decoder.decode(Metadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.schemaVersion <= Self.metadataSchemaVersion else {
            throw LabError.invalid("These profiles were saved by a newer Tactile Lab (schema \(metadata.schemaVersion)).")
        }
        return metadata
    }

    private func writeMetadata(_ metadata: Metadata) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    /// Writes the given profiles' library files (all when nil), removes
    /// `deleted`, then the metadata.
    private func persist(saving changed: [LabProfile]? = nil, deleting deleted: [String] = []) {
        do {
            for profile in changed ?? profiles { try library.save(profile.controllerProfile) }
            for id in deleted { try library.delete(id: id) }
            try writeMetadata(Metadata(activeID: activeID, order: profiles.map(\.id),
                                       extras: Dictionary(profiles.map { ($0.id, $0.extras) }, uniquingKeysWith: { first, _ in first })))
            lastError = nil
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    // MARK: Editing

    @discardableResult
    func add(_ profile: LabProfile) -> LabProfile {
        var copy = profile
        if profiles.contains(where: { $0.id == copy.id }) { copy.id = UUID().uuidString }
        copy.name = uniqueName(copy.name)
        copy.createdAt = Date(); copy.modifiedAt = Date()
        profiles.append(copy)
        persist(saving: [copy])
        return copy
    }

    func update(_ profile: LabProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var copy = profile
        copy.modifiedAt = Date()
        profiles[index] = copy
        persist(saving: [copy])
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[index].name != trimmed else { return }
        profiles[index].name = uniqueName(trimmed, excluding: id)
        profiles[index].modifiedAt = Date()
        persist(saving: [profiles[index]])
    }

    @discardableResult
    func duplicate(_ id: String) -> LabProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID().uuidString
        copy.name = "\(original.name) copy"
        return add(copy)
    }

    func delete(_ ids: Set<String>) {
        let removed = profiles.filter { ids.contains($0.id) }.map(\.id)
        profiles.removeAll { ids.contains($0.id) }
        if let activeID, ids.contains(activeID) { self.activeID = nil }
        persist(saving: [], deleting: removed)
    }

    func setActive(_ id: String?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist(saving: [])
    }

    // MARK: Import and export

    /// JSON for the given profiles (all when `ids` is nil), in the archive format.
    func exportData(_ ids: Set<String>? = nil) throws -> Data {
        let selected = ids.map { set in profiles.filter { set.contains($0.id) } } ?? profiles
        return try Self.encoder.encode(Archive(activeID: nil, profiles: selected))
    }

    func export(_ ids: Set<String>? = nil, to url: URL) throws {
        try exportData(ids).write(to: url, options: .atomic)
    }

    /// Imports profiles from an archive, an array, a single profile, or a
    /// library `.tactileprofile`. Imported profiles get fresh identities and
    /// unique names, and a gain clamped to 0–1; returns what was added.
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
        } else if let single = try? Self.decoder.decode(LabProfile.self, from: data) {
            incoming = [single]
        } else if let library = try? ControllerProfile(data: data), Self.looksLikeLibraryProfile(data) {
            incoming = [LabProfile(library)]
        } else {
            throw LabError.invalid("This file is not a Tactile Lab profile export or a .tactileprofile.")
        }
        var added: [LabProfile] = []
        for var profile in incoming {
            profile.id = UUID().uuidString
            profile.name = uniqueName(profile.name.isEmpty ? "Imported profile" : profile.name)
            profile.hapticGain = profile.hapticGain.isFinite ? min(max(profile.hapticGain, 0), 1) : 1
            profile.modifiedAt = Date()
            profiles.append(profile)
            added.append(profile)
        }
        persist(saving: added)
        return added
    }

    @discardableResult
    func importProfiles(from url: URL) throws -> [LabProfile] { try importProfiles(from: Data(contentsOf: url)) }

    // MARK: Applying

    /// Applies a profile through the session's existing output operation and
    /// marks it active. The lights and triggers last the session's test
    /// length, after which outputs return to neutral, like every other Tactile
    /// Lab effect; the haptic gain stays in force for every later haptic while
    /// the profile is active (`LabSession.hapticGain`). A simulated session
    /// sends nothing to hardware.
    func apply(_ profile: LabProfile, to session: LabSession) {
        guard profile.problems.isEmpty else { session.showError(LabError.invalid(profile.problems.joined(separator: " "))); return }
        setActive(profile.id)
        if session.profiles == nil { session.profiles = self }
        session.perform(.output(profile.outputState), name: "Profile: \(profile.name)", settings: profile.summary)
    }

    // MARK: Helpers

    /// "Name", or "Name 2", "Name 3"… if already taken.
    func uniqueName(_ name: String, excluding id: String? = nil) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Profile" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// `ControllerProfile` decodes almost any JSON object (every field has a
    /// default), so only take a file as one when it has a library key.
    nonisolated static func looksLikeLibraryProfile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["name"] != nil && (object["hapticGain"] != nil || object["schemaVersion"] != nil)
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
