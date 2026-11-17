import Foundation
import Tactile

/// One sampled input frame. Times are seconds from the start of the capture.
struct InputLabFrame: Sendable, Hashable, Codable {
    var t: Double
    var lx: UInt8, ly: UInt8
    var rx: UInt8, ry: UInt8
    var l2: UInt8, r2: UInt8
    var buttons: UInt32
    var battery: Int?
    var charging: String?

    init(t: Double, left: SIMD2<UInt8>, right: SIMD2<UInt8>, l2: UInt8, r2: UInt8, buttons: UInt32, battery: Int? = nil, charging: String? = nil) {
        self.t = t; lx = left.x; ly = left.y; rx = right.x; ry = right.y
        self.l2 = l2; self.r2 = r2; self.buttons = buttons; self.battery = battery; self.charging = charging
    }

    init(_ state: InputState, t: Double) {
        self.init(t: t, left: state.leftStick, right: state.rightStick, l2: state.l2, r2: state.r2,
                  buttons: state.buttons.rawValue, battery: state.battery?.percent, charging: state.battery?.charging.rawValue)
    }

    var leftStick: SIMD2<UInt8> { SIMD2(lx, ly) }
    var rightStick: SIMD2<UInt8> { SIMD2(rx, ry) }
    var left: StickPoint { StickPoint(raw: leftStick) }
    var right: StickPoint { StickPoint(raw: rightStick) }
    var pressed: Buttons { Buttons(rawValue: buttons) }
}

/// A saved Input Lab session. Named `InputLabRecording` so it does not clash
/// with the Tactile library's forthcoming `InputRecording`; convert between
/// the two in one adapter once that type exists.
struct InputLabRecording: Sendable, Hashable, Codable {
    static let currentSchema = 1
    var schemaVersion = InputLabRecording.currentSchema
    var createdAt = Date()
    var deviceName: String
    var model: String
    var simulated: Bool
    var frames: [InputLabFrame]
    /// Arrival times of individual input reports, seconds from the start.
    var reportTimes: [Double]

    var duration: Double { max(frames.last?.t ?? 0, reportTimes.last ?? 0) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> InputLabRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(InputLabRecording.self, from: data)
        guard recording.schemaVersion <= currentSchema else {
            throw LabError.invalid("This recording was made by a newer Tactile Lab (schema \(recording.schemaVersion)).")
        }
        return recording
    }
}

/// The named buttons the timing table reports, as (name, mask) pairs.
enum InputLabButtons {
    static let all: [(String, UInt32)] = ButtonName.all.map { ($0.name, $0.value.rawValue) }
}
