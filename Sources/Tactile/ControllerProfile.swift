// Controller profiles: a named set of lightbar, player LEDs, trigger effects,
// haptic gain and a preferred pattern, stored as JSON in Application Support.

public import Foundation
public import TactileCore
import TactileHaptics
import TactileTransport

/// A saved controller set-up. Every field is optional except the name and
/// gain: a nil field leaves that output as it is when applied.
public struct ControllerProfile: Sendable, Hashable, Codable, Identifiable {
    public static let fileExtension = "tactileprofile"
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var lightbar: LightbarColor?
    public var playerLEDs: PlayerLEDs?
    public var playerLEDBrightness: LEDBrightness?
    public var leftTrigger: TriggerEffectSpec?
    public var rightTrigger: TriggerEffectSpec?
    /// Haptics master gain, 0…1.
    public var hapticGain: Float
    /// A `.tactilepattern` path (or a name the app resolves) to play with this profile.
    public var preferredPattern: String?

    public init(id: String = UUID().uuidString, name: String, lightbar: LightbarColor? = nil,
                playerLEDs: PlayerLEDs? = nil, playerLEDBrightness: LEDBrightness? = nil,
                leftTrigger: TriggerEffectSpec? = nil, rightTrigger: TriggerEffectSpec? = nil,
                hapticGain: Float = 1, preferredPattern: String? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.lightbar = lightbar
        self.playerLEDs = playerLEDs
        self.playerLEDBrightness = playerLEDBrightness
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.hapticGain = hapticGain
        self.preferredPattern = preferredPattern
    }

    public enum Failure: Error, Sendable, Equatable {
        case unsupportedSchemaVersion(Int)
        case invalidTrigger(TriggerSide, String)
    }

    /// The output report patch this profile applies. Throws for an invalid trigger spec.
    public func outputState() throws -> OutputState {
        func effect(_ spec: TriggerEffectSpec?, _ side: TriggerSide) throws -> TriggerEffect? {
            guard let spec else { return nil }
            do { return try spec.effect() } catch { throw Failure.invalidTrigger(side, "\(error)") }
        }
        return OutputState(leftTrigger: try effect(leftTrigger, .left), rightTrigger: try effect(rightTrigger, .right),
                           lightbar: lightbar, playerLEDs: playerLEDs, playerLEDBrightness: playerLEDBrightness)
    }

    public var clampedGain: Float { hapticGain.isNaN ? 1 : min(max(hapticGain, 0), 1) }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, lightbar, playerLEDs, playerLEDBrightness, leftTrigger, rightTrigger
        case hapticGain, preferredPattern
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard v <= Self.currentSchemaVersion else { throw Failure.unsupportedSchemaVersion(v) }
        schemaVersion = v
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        lightbar = try c.decodeIfPresent(LightbarColor.self, forKey: .lightbar)
        playerLEDs = try c.decodeIfPresent(PlayerLEDs.self, forKey: .playerLEDs)
        playerLEDBrightness = try c.decodeIfPresent(LEDBrightness.self, forKey: .playerLEDBrightness)
        leftTrigger = try c.decodeIfPresent(TriggerEffectSpec.self, forKey: .leftTrigger)
        rightTrigger = try c.decodeIfPresent(TriggerEffectSpec.self, forKey: .rightTrigger)
        hapticGain = try c.decodeIfPresent(Float.self, forKey: .hapticGain) ?? 1
        preferredPattern = try c.decodeIfPresent(String.self, forKey: .preferredPattern)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ControllerProfile.self, from: data)
    }
}

extension Controller {
    /// Applies a profile: one output report for lights and triggers, then the
    /// haptic gain. The preferred pattern is not started (the app decides).
    public func apply(_ profile: ControllerProfile) async throws {
        let patch = try profile.outputState()
        haptics.setGain(profile.clampedGain)
        if patch != OutputState() { try await apply(patch) }
    }
}

/// Profiles as `<id>.tactileprofile` JSON files in one directory.
public final class ProfileStore: Sendable {
    public let directory: URL

    /// `~/Library/Application Support/<bundle identifier or "Tactile">/Profiles`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tactile", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    /// - Parameter directory: where profiles live (tests inject a temporary folder).
    public init(directory: URL = ProfileStore.defaultDirectory) {
        self.directory = directory
    }

    public func url(for id: String) -> URL {
        // Keep ids file-name safe.
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).\(ControllerProfile.fileExtension)")
    }

    /// All readable profiles, sorted by name. Unreadable files are skipped.
    public func list() throws -> [ControllerProfile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ControllerProfile.fileExtension }
        return files.compactMap { try? ControllerProfile(data: Data(contentsOf: $0)) }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    public func save(_ profile: ControllerProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try profile.encoded().write(to: url(for: profile.id), options: .atomic)
    }

    public func load(id: String) throws -> ControllerProfile? {
        let u = url(for: id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try ControllerProfile(data: Data(contentsOf: u))
    }

    public func delete(id: String) throws {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}
