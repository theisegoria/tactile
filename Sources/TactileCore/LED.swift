// LED encodings: player indicator, mute LED, lightbar.

/// The five white player-indicator LEDs under the touchpad (bit 0 = leftmost).
public struct PlayerLEDs: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x3F }

    public static let led1 = PlayerLEDs(rawValue: 1 << 0)
    public static let led2 = PlayerLEDs(rawValue: 1 << 1)
    public static let led3 = PlayerLEDs(rawValue: 1 << 2)
    public static let led4 = PlayerLEDs(rawValue: 1 << 3)
    public static let led5 = PlayerLEDs(rawValue: 1 << 4)
    /// Switch instantly instead of fading (bit 5).
    public static let instant = PlayerLEDs(rawValue: 1 << 5)

    public static let none: PlayerLEDs = []

    /// Sony's conventional patterns for players 1–5 (centre-out). Other values → none.
    public static func player(_ n: Int) -> PlayerLEDs {
        switch n {
        case 1: PlayerLEDs(rawValue: 0x04)
        case 2: PlayerLEDs(rawValue: 0x0A)
        case 3: PlayerLEDs(rawValue: 0x15)
        case 4: PlayerLEDs(rawValue: 0x1B)
        case 5: PlayerLEDs(rawValue: 0x1F)
        default: .none
        }
    }
}

/// Microphone mute LED.
public enum MuteLED: UInt8, Sendable, Codable, CaseIterable {
    case off = 0
    case on = 1
    case pulse = 2
}

/// Lightbar colour, 8 bits per channel.
public struct LightbarColor: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let off = LightbarColor(red: 0, green: 0, blue: 0)
    /// Approximation of the default blue the controller shows for player 1.
    public static let defaultBlue = LightbarColor(red: 0, green: 0, blue: 64)

    /// Parses "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        red = UInt8(truncatingIfNeeded: v >> 16)
        green = UInt8(truncatingIfNeeded: v >> 8)
        blue = UInt8(truncatingIfNeeded: v)
    }
}

/// Global LED brightness for the player LEDs (byte 42).
public enum LEDBrightness: UInt8, Sendable, Codable, CaseIterable {
    case high = 0
    case medium = 1
    case low = 2
}
