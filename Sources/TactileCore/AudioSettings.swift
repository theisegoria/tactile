// EXPERIMENTAL (gate 6): audio routing and volume fields of output report
// 0x31 / 0x02, common-block bytes 4–7 with valid_flag0 bits 4–7.
// Bit positions come from the Linux driver's audio-jack work (facts only);
// the meaning of individual audio-control values is 🔬 unverified.

/// Where the controller plays audio (audio-control byte, bits 4–5). 🔬
public enum AudioOutputPath: UInt8, Sendable, Codable, CaseIterable {
    /// Stereo to the 3.5 mm headphone jack.
    case headphones = 0
    /// Left headphone channel only (mono headset). 🔬
    case headphoneLeft = 1
    /// Left headphone channel plus the internal speaker. 🔬
    case headphoneLeftAndSpeaker = 2
    /// Internal speaker only.
    case speaker = 3
}

/// Audio settings carried in the common output block. Like every other output
/// field, `nil` means "not controlled": its valid flag stays clear.
public struct AudioSettings: Sendable, Hashable, Codable {
    /// Headphone volume, 0…0x7F. 🔬 range
    public var headphoneVolume: UInt8?
    /// Internal speaker volume, 0…0xFF. 🔬 range
    public var speakerVolume: UInt8?
    /// Microphone gain, 0…0x40. 🔬 range
    public var micVolume: UInt8?
    /// Output path; encoded into the audio-control byte.
    public var outputPath: AudioOutputPath?
    /// Extra audio-control bits OR-ed in when `outputPath` is set (research use).
    public var audioControlExtraBits: UInt8

    public init(headphoneVolume: UInt8? = nil, speakerVolume: UInt8? = nil, micVolume: UInt8? = nil,
                outputPath: AudioOutputPath? = nil, audioControlExtraBits: UInt8 = 0) {
        self.headphoneVolume = headphoneVolume
        self.speakerVolume = speakerVolume
        self.micVolume = micVolume
        self.outputPath = outputPath
        self.audioControlExtraBits = audioControlExtraBits
    }

    /// Returns `self` with every non-nil field of `other` applied on top.
    public func merging(_ other: AudioSettings) -> AudioSettings {
        var s = self
        if let v = other.headphoneVolume { s.headphoneVolume = v }
        if let v = other.speakerVolume { s.speakerVolume = v }
        if let v = other.micVolume { s.micVolume = v }
        if let v = other.outputPath {
            s.outputPath = v
            s.audioControlExtraBits = other.audioControlExtraBits
        }
        return s
    }

    /// The audio-control byte for `outputPath` (bits 4–5) plus extra bits.
    public var audioControlByte: UInt8? {
        outputPath.map { ($0.rawValue & 0x03) << 4 | (audioControlExtraBits & ~0x30) }
    }

    /// Encodes into a 47-byte common block (flags and bytes 4–7).
    public func encode(into c: inout [UInt8]) {
        typealias L = OutputLayout
        guard c.count >= L.commonLength else { return }
        if let v = headphoneVolume {
            c[L.validFlag0] |= L.flag0HeadphoneVolume
            c[L.headphoneVolume] = min(v, 0x7F)
        }
        if let v = speakerVolume {
            c[L.validFlag0] |= L.flag0SpeakerVolume
            c[L.speakerVolume] = v
        }
        if let v = micVolume {
            c[L.validFlag0] |= L.flag0MicVolume
            c[L.micVolume] = min(v, 0x40)
        }
        if let b = audioControlByte {
            c[L.validFlag0] |= L.flag0AudioControl
            c[L.audioControl] = b
        }
    }
}
