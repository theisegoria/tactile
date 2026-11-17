// ABI 0.4 entry points: trigger presets, haptic patterns, profiles.

public import CTactileHeaders
import Foundation
import Tactile

private let OK = TACTILE_OK.rawValue
private let EINVAL = TACTILE_ERR_INVALID_ARGUMENT.rawValue

private func controllerBox(_ p: OpaquePointer?) -> ControllerBox? {
    p.map { Unmanaged<ControllerBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

private func patternBox(_ p: OpaquePointer?) -> PatternBox? {
    p.map { Unmanaged<PatternBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

/// Maps loading/decoding failures to result codes.
private func loadCode(_ error: any Error) -> Int32 {
    switch error {
    case HapticPattern.Failure.unsupportedSchemaVersion, ControllerProfile.Failure.unsupportedSchemaVersion:
        return TACTILE_ERR_VERSION.rawValue
    case HapticPattern.Failure.unreadableClip:
        return TACTILE_ERR_IO.rawValue
    case let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile:
        return TACTILE_ERR_NOT_FOUND.rawValue
    case is CocoaError:
        return TACTILE_ERR_IO.rawValue
    default:
        return EINVAL
    }
}

private func jsonData(_ json: UnsafePointer<CChar>?, _ length: Int) -> Data? {
    guard let json else { return nil }
    if length > 0 { return Data(bytes: json, count: length) }
    return Data(bytes: json, count: strlen(json))
}

// MARK: Trigger presets

/// `TriggerPreset` for a `tactile_trigger_preset` value (ABI order).
func triggerPreset(_ raw: Int32) -> TriggerPreset? {
    switch UInt32(bitPattern: raw) {
    case TACTILE_TRIGGER_PRESET_OFF.rawValue: .off
    case TACTILE_TRIGGER_PRESET_WEAPON.rawValue: .weaponTrigger
    case TACTILE_TRIGGER_PRESET_BOW.rawValue: .bowDraw
    case TACTILE_TRIGGER_PRESET_BRAKE.rawValue: .brakePedal
    case TACTILE_TRIGGER_PRESET_CLICK.rawValue: .clickDetent
    case TACTILE_TRIGGER_PRESET_MACHINE_GUN.rawValue: .machineGun
    case TACTILE_TRIGGER_PRESET_GALLOP.rawValue: .gallop
    default: nil
    }
}

@_cdecl("tactile_trigger_from_preset")
public func tactile_trigger_from_preset(_ preset: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    guard let out, let p = triggerPreset(preset) else { return EINVAL }
    let bytes = p.effect.bytes
    withUnsafeMutableBytes(of: &out.pointee.bytes) { dst in
        for (i, b) in bytes.enumerated() where i < dst.count { dst[i] = b }
    }
    return OK
}

// MARK: Patterns

@_cdecl("tactile_pattern_load_file")
public func tactile_pattern_load_file(_ path: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let path, let out else { return EINVAL }
    out.pointee = nil
    let url = URL(fileURLWithPath: String(cString: path))
    do {
        let pattern = try HapticPattern(contentsOf: url)
        let box = try PatternBox(pattern: pattern, clipBase: url.deletingLastPathComponent())
        out.pointee = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
        return OK
    } catch {
        return loadCode(error)
    }
}

@_cdecl("tactile_pattern_load_json")
public func tactile_pattern_load_json(_ json: UnsafePointer<CChar>?, _ length: Int, _ clipBase: UnsafePointer<CChar>?,
                                      _ out: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let out, let data = jsonData(json, length) else { return EINVAL }
    out.pointee = nil
    let base = clipBase.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
    do {
        let box = try PatternBox(pattern: HapticPattern(data: data), clipBase: base)
        out.pointee = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
        return OK
    } catch {
        return loadCode(error)
    }
}

@_cdecl("tactile_pattern_free")
public func tactile_pattern_free(_ p: OpaquePointer?) {
    guard let p else { return }
    Unmanaged<PatternBox>.fromOpaque(UnsafeRawPointer(p)).release()
}

@_cdecl("tactile_pattern_duration")
public func tactile_pattern_duration(_ p: OpaquePointer?) -> Double {
    patternBox(p)?.preview.duration ?? 0
}

@_cdecl("tactile_pattern_render")
public func tactile_pattern_render(_ p: OpaquePointer?, _ left: UnsafeMutablePointer<Float>?, _ right: UnsafeMutablePointer<Float>?,
                                   _ capacity: Int32) -> Int32 {
    guard let box = patternBox(p), capacity >= 0 else { return EINVAL }
    let preview = box.preview
    let n = min(preview.frameCount, Int(capacity))
    if let left { for i in 0..<n { left[i] = preview.left[i] } }
    if let right { for i in 0..<n { right[i] = preview.right[i] } }
    return Int32(clamping: preview.frameCount)
}

@_cdecl("tactile_pattern_play")
public func tactile_pattern_play(_ c: OpaquePointer?, _ p: OpaquePointer?) -> Int32 {
    guard let b = controllerBox(c), let box = patternBox(p) else { return EINVAL }
    guard b.isLive else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    let controller = b.controller
    let player = HapticPatternPlayer(pattern: box.pattern, preview: box.preview, mixer: controller.haptics, output: controller)
    b.setPattern(player)
    return b.enqueue { () async throws(TransportError) in
        // Skipped if another pattern replaced this one meanwhile.
        guard b.currentPattern() === player else { return }
        do throws(TransportError) {
            try await controller.startHaptics()
        } catch {
            b.setPattern(nil)
            throw error
        }
        guard b.currentPattern() === player else { return }
        player.start()
    }
}

@_cdecl("tactile_pattern_stop")
public func tactile_pattern_stop(_ c: OpaquePointer?) -> Int32 {
    guard let b = controllerBox(c) else { return EINVAL }
    b.stopPattern()
    return OK
}

@_cdecl("tactile_pattern_is_playing")
public func tactile_pattern_is_playing(_ c: OpaquePointer?) -> Int32 {
    guard let b = controllerBox(c) else { return EINVAL }
    return b.currentPattern()?.isPlaying == true ? 1 : 0
}

// MARK: Profiles

private func applyProfile(_ b: ControllerBox, _ profile: ControllerProfile) -> Int32 {
    let patch: OutputState
    do { patch = try profile.outputState() } catch { return EINVAL }
    guard b.isLive else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    let c = b.controller
    let gain = profile.clampedGain
    return b.enqueue { () async throws(TransportError) in
        c.haptics.setGain(gain)
        if patch != OutputState() { try await c.apply(patch) }
    }
}

@_cdecl("tactile_profile_apply_file")
public func tactile_profile_apply_file(_ c: OpaquePointer?, _ path: UnsafePointer<CChar>?) -> Int32 {
    guard let b = controllerBox(c), let path else { return EINVAL }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: String(cString: path)))
        return applyProfile(b, try ControllerProfile(data: data))
    } catch {
        return loadCode(error)
    }
}

@_cdecl("tactile_profile_apply_json")
public func tactile_profile_apply_json(_ c: OpaquePointer?, _ json: UnsafePointer<CChar>?, _ length: Int) -> Int32 {
    guard let b = controllerBox(c), let data = jsonData(json, length) else { return EINVAL }
    do {
        return applyProfile(b, try ControllerProfile(data: data))
    } catch {
        return loadCode(error)
    }
}
