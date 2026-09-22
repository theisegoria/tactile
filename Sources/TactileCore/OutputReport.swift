// Output report 0x31 (Bluetooth) / 0x02 (USB) construction.
// Layout facts: PROTOCOL.md §Output. Offsets are into the 47-byte common block.

/// Rumble motor intensities (the legacy "compatible vibration" path).
public struct Rumble: Sendable, Hashable, Codable {
    /// Left, heavier low-frequency actuator (0–255).
    public var left: UInt8
    /// Right, lighter high-frequency actuator (0–255).
    public var right: UInt8

    public init(left: UInt8, right: UInt8) {
        self.left = left
        self.right = right
    }

    public static let off = Rumble(left: 0, right: 0)
}

/// Desired controller output. A `nil` field is *not controlled*: its valid flag
/// is left clear so the controller keeps whatever another writer last set.
/// Because each report carries full state for every flagged field, whichever
/// process writes a flagged field last wins.
public struct OutputState: Sendable, Hashable, Codable {
    public var rumble: Rumble?
    public var leftTrigger: TriggerEffect?
    public var rightTrigger: TriggerEffect?
    public var lightbar: LightbarColor?
    public var playerLEDs: PlayerLEDs?
    public var playerLEDBrightness: LEDBrightness?
    public var muteLED: MuteLED?
    /// Hardware microphone mute (power-save control bit 4).
    public var micMuted: Bool?
    /// When true the report also asks the firmware to fade out its own boot
    /// lightbar animation, which is required once before lightbar colours apply.
    public var releaseLightbarAnimation: Bool

    public init(
        rumble: Rumble? = nil, leftTrigger: TriggerEffect? = nil, rightTrigger: TriggerEffect? = nil,
        lightbar: LightbarColor? = nil, playerLEDs: PlayerLEDs? = nil, playerLEDBrightness: LEDBrightness? = nil,
        muteLED: MuteLED? = nil, micMuted: Bool? = nil, releaseLightbarAnimation: Bool = false
    ) {
        self.rumble = rumble
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.lightbar = lightbar
        self.playerLEDs = playerLEDs
        self.playerLEDBrightness = playerLEDBrightness
        self.muteLED = muteLED
        self.micMuted = micMuted
        self.releaseLightbarAnimation = releaseLightbarAnimation
    }

    /// The state written on disconnect, quit or crash recovery: rumble off,
    /// triggers off, lightbar restored to `restoreLightbar`.
    public static func neutral(restoreLightbar: LightbarColor = .defaultBlue) -> OutputState {
        OutputState(rumble: .off, leftTrigger: .off, rightTrigger: .off, lightbar: restoreLightbar)
    }

    /// Returns `self` with every non-nil field of `other` applied on top.
    public func merging(_ other: OutputState) -> OutputState {
        var s = self
        if let v = other.rumble { s.rumble = v }
        if let v = other.leftTrigger { s.leftTrigger = v }
        if let v = other.rightTrigger { s.rightTrigger = v }
        if let v = other.lightbar { s.lightbar = v }
        if let v = other.playerLEDs { s.playerLEDs = v }
        if let v = other.playerLEDBrightness { s.playerLEDBrightness = v }
        if let v = other.muteLED { s.muteLED = v }
        if let v = other.micMuted { s.micMuted = v }
        s.releaseLightbarAnimation = s.releaseLightbarAnimation || other.releaseLightbarAnimation
        return s
    }
}

/// Valid-flag bits and common-block offsets.
public enum OutputLayout {
    public static let commonLength = 47
    public static let usbReportID: UInt8 = 0x02
    public static let usbLength = 63
    public static let bluetoothReportID: UInt8 = 0x31
    public static let bluetoothLength = 78
    /// Offset of the common block inside the Bluetooth report.
    public static let bluetoothCommonOffset = 3
    /// Constant tag byte at Bluetooth offset 2.
    public static let bluetoothTag: UInt8 = 0x10

    // Common-block offsets.
    public static let validFlag0 = 0
    public static let validFlag1 = 1
    public static let motorRight = 2
    public static let motorLeft = 3
    public static let muteLED = 8
    public static let powerSaveControl = 9
    public static let rightTrigger = 10
    public static let leftTrigger = 21
    public static let validFlag2 = 38
    public static let lightbarSetup = 41
    public static let ledBrightness = 42
    public static let playerLEDs = 43
    public static let lightbarRed = 44

    // valid_flag0
    public static let flag0CompatibleVibration: UInt8 = 1 << 0
    public static let flag0HapticsSelect: UInt8 = 1 << 1
    public static let flag0RightTrigger: UInt8 = 1 << 2
    public static let flag0LeftTrigger: UInt8 = 1 << 3
    // valid_flag1
    public static let flag1MuteLED: UInt8 = 1 << 0
    public static let flag1PowerSave: UInt8 = 1 << 1
    public static let flag1Lightbar: UInt8 = 1 << 2
    public static let flag1ReleaseLEDs: UInt8 = 1 << 3
    public static let flag1PlayerIndicator: UInt8 = 1 << 4
    // valid_flag2
    public static let flag2LightbarSetup: UInt8 = 1 << 1
    public static let flag2CompatibleVibration2: UInt8 = 1 << 2

    public static let powerSaveMicMute: UInt8 = 1 << 4
    public static let lightbarSetupLightOut: UInt8 = 1 << 1
}

/// Encodes `OutputState` into wire reports. Holds the Bluetooth sequence counter,
/// so keep one builder per device.
public struct OutputReportBuilder: Sendable {
    public var features: FeatureSet
    /// 4-bit Bluetooth sequence number, incremented per Bluetooth report.
    public private(set) var sequence: UInt8 = 0

    public init(features: FeatureSet) {
        self.features = features
    }

    /// Encodes the 47-byte common block.
    public func encodeCommon(_ s: OutputState) -> [UInt8] {
        typealias L = OutputLayout
        var c = [UInt8](repeating: 0, count: L.commonLength)
        if let r = s.rumble {
            c[L.validFlag0] |= L.flag0HapticsSelect
            if features.vibrationV2 {
                c[L.validFlag2] |= L.flag2CompatibleVibration2
            } else {
                c[L.validFlag0] |= L.flag0CompatibleVibration
            }
            c[L.motorRight] = r.right
            c[L.motorLeft] = r.left
        }
        if let t = s.rightTrigger {
            c[L.validFlag0] |= L.flag0RightTrigger
            c.replaceSubrange(L.rightTrigger..<(L.rightTrigger + TriggerEffect.byteCount), with: t.bytes)
        }
        if let t = s.leftTrigger {
            c[L.validFlag0] |= L.flag0LeftTrigger
            c.replaceSubrange(L.leftTrigger..<(L.leftTrigger + TriggerEffect.byteCount), with: t.bytes)
        }
        if let m = s.muteLED {
            c[L.validFlag1] |= L.flag1MuteLED
            c[L.muteLED] = m.rawValue
        }
        if let muted = s.micMuted {
            c[L.validFlag1] |= L.flag1PowerSave
            if muted { c[L.powerSaveControl] |= L.powerSaveMicMute }
        }
        if let color = s.lightbar {
            c[L.validFlag1] |= L.flag1Lightbar
            c[L.lightbarRed] = color.red
            c[L.lightbarRed + 1] = color.green
            c[L.lightbarRed + 2] = color.blue
        }
        if let p = s.playerLEDs {
            c[L.validFlag1] |= L.flag1PlayerIndicator
            c[L.playerLEDs] = p.rawValue
        }
        if let b = s.playerLEDBrightness {
            // No dedicated valid flag is known; the byte is applied together with
            // the player-indicator flag (UNVERIFIED, see PROTOCOL.md).
            c[L.ledBrightness] = b.rawValue
        }
        if s.releaseLightbarAnimation {
            c[L.validFlag2] |= L.flag2LightbarSetup
            c[L.lightbarSetup] = L.lightbarSetupLightOut
        }
        return c
    }

    /// Builds a complete output report for `transport`. Bluetooth reports carry a
    /// valid CRC (seed 0xA2) and consume one sequence number.
    public mutating func build(_ s: OutputState, transport: Transport) -> [UInt8] {
        let common = encodeCommon(s)
        switch transport {
        case .usb:
            var r = [UInt8](repeating: 0, count: OutputLayout.usbLength)
            r[0] = OutputLayout.usbReportID
            r.replaceSubrange(1...common.count, with: common)
            return r
        case .bluetooth:
            var r = [UInt8](repeating: 0, count: OutputLayout.bluetoothLength)
            r[0] = OutputLayout.bluetoothReportID
            r[1] = sequence << 4
            r[2] = OutputLayout.bluetoothTag
            let o = OutputLayout.bluetoothCommonOffset
            r.replaceSubrange(o..<(o + common.count), with: common)
            CRC32.seal(&r, prefix: .output)
            sequence = (sequence + 1) & 0x0F
            return r
        }
    }
}
