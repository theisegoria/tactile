// @_cdecl entry points implementing Sources/CTactileHeaders/include/tactile.h.
// Thread-safety of each call is documented in the header and THREADING.md.

public import CTactileHeaders
import Foundation
import Tactile

// MARK: Helpers

private let OK = TACTILE_OK.rawValue
private let EINVAL = TACTILE_ERR_INVALID_ARGUMENT.rawValue

private func context(_ p: OpaquePointer?) -> ContextBox? {
    p.map { Unmanaged<ContextBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

private func controller(_ p: OpaquePointer?) -> ControllerBox? {
    p.map { Unmanaged<ControllerBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

private func retained(_ b: ControllerBox) -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(b).toOpaque())
}

/// Copies `value` into a caller struct honouring its `struct_size` prefix.
private func copyOut<T>(_ value: T, to out: UnsafeMutablePointer<T>) {
    let callerSize = Int(UnsafeRawPointer(out).load(as: UInt32.self))
    let n = min(callerSize, MemoryLayout<T>.size)
    guard n > 4 else { return }
    withUnsafeBytes(of: value) { src in
        UnsafeMutableRawPointer(out).advanced(by: 4).copyMemory(from: src.baseAddress!.advanced(by: 4), byteCount: n - 4)
    }
}

private func triggerOut(_ make: () throws -> TriggerEffect, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    guard let out else { return EINVAL }
    guard let e = try? make() else { return EINVAL }
    withUnsafeMutableBytes(of: &out.pointee.bytes) { dst in
        for (i, b) in e.bytes.enumerated() where i < dst.count { dst[i] = b }
    }
    return OK
}

nonisolated(unsafe) private let versionCString: UnsafePointer<CChar> = UnsafePointer(strdup(TactileVersion.string)!)

nonisolated(unsafe) private let resultStrings: [Int32: UnsafePointer<CChar>] = {
    let pairs: [(tactile_result, String)] = [
        (TACTILE_OK, "ok"), (TACTILE_ERR_INVALID_ARGUMENT, "invalid argument"),
        (TACTILE_ERR_NOT_CONNECTED, "controller not connected"),
        (TACTILE_ERR_PERMISSION, "Input Monitoring permission required"), (TACTILE_ERR_IO, "HID I/O error"),
        (TACTILE_ERR_UNSUPPORTED, "not supported"), (TACTILE_ERR_TIMEOUT, "timeout"),
        (TACTILE_ERR_BUSY, "another process has exclusive access"), (TACTILE_ERR_VERSION, "ABI version mismatch"),
        (TACTILE_ERR_NOT_FOUND, "not found"),
    ]
    return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue, UnsafePointer(strdup($0.1)!)) })
}()
nonisolated(unsafe) private let unknownResult: UnsafePointer<CChar> = UnsafePointer(strdup("unknown result")!)

// MARK: Library

@_cdecl("tactile_abi_version")
public func tactile_abi_version() -> UInt32 { UInt32(TACTILE_ABI_VERSION_MAJOR) << 16 | UInt32(TACTILE_ABI_VERSION_MINOR) }

@_cdecl("tactile_version_string")
public func tactile_version_string() -> UnsafePointer<CChar> { versionCString }

@_cdecl("tactile_result_string")
public func tactile_result_string(_ r: Int32) -> UnsafePointer<CChar> { resultStrings[r] ?? unknownResult }

@_cdecl("tactile_permission_status")
public func tactile_permission_status() -> Int32 {
    switch InputMonitoringPermission.status {
    case .granted: Int32(TACTILE_PERMISSION_GRANTED.rawValue)
    case .denied: Int32(TACTILE_PERMISSION_DENIED.rawValue)
    case .notDetermined: Int32(TACTILE_PERMISSION_NOT_DETERMINED.rawValue)
    }
}

@_cdecl("tactile_permission_request")
public func tactile_permission_request() -> Int32 {
    InputMonitoringPermission.request() ? OK : TACTILE_ERR_PERMISSION.rawValue
}

// MARK: Context

@_cdecl("tactile_context_create")
public func tactile_context_create(_ options: UnsafePointer<tactile_options>?, _ out: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let out else { return EINVAL }
    var o = ConnectionOptions()
    if let options {
        let size = Int(options.pointee.struct_size)
        if size >= MemoryLayout<tactile_options>.offset(of: \.mode)! + 4 {
            o.mode = options.pointee.mode == Int32(TACTILE_MODE_EXCLUSIVE.rawValue) ? .exclusive : .shared
        }
        if size >= MemoryLayout<tactile_options>.size, options.pointee.max_output_reports_per_second > 0 {
            o.maxOutputReportsPerSecond = options.pointee.max_output_reports_per_second
        }
    }
    let box = ContextBox(options: o)
    out.pointee = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
    return OK
}

@_cdecl("tactile_context_destroy")
public func tactile_context_destroy(_ ctx: OpaquePointer?) {
    guard let ctx, let box = context(ctx) else { return }
    box.shutdown()
    Unmanaged<ContextBox>.fromOpaque(UnsafeRawPointer(ctx)).release()
}

@_cdecl("tactile_context_set_callback")
public func tactile_context_set_callback(_ ctx: OpaquePointer?, _ cb: tactile_event_callback?, _ user: UnsafeMutableRawPointer?) {
    context(ctx)?.setCallback(cb, user)
}

@_cdecl("tactile_context_controller_count")
public func tactile_context_controller_count(_ ctx: OpaquePointer?) -> Int32 {
    Int32(context(ctx)?.count ?? 0)
}

@_cdecl("tactile_context_get_controller")
public func tactile_context_get_controller(_ ctx: OpaquePointer?, _ index: Int32, _ out: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let c = context(ctx), let out else { return EINVAL }
    guard let b = c.box(at: Int(index)) else { return TACTILE_ERR_NOT_FOUND.rawValue }
    out.pointee = retained(b)
    return OK
}

@_cdecl("tactile_context_wait_for_controller")
public func tactile_context_wait_for_controller(_ ctx: OpaquePointer?, _ timeoutMs: Int32, _ out: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let c = context(ctx), let out else { return EINVAL }
    let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 0)) / 1000)
    repeat {
        if let b = c.firstConnected() {
            out.pointee = retained(b)
            return OK
        }
        usleep(10_000)
    } while Date() < deadline
    guard InputMonitoringPermission.status == .granted else { return TACTILE_ERR_PERMISSION.rawValue }
    // A controller was found but could not be opened (e.g. another process
    // holds exclusive access): say why instead of a bare timeout.
    let openError = c.lastOpenError.exchange(0, ordering: .relaxed)
    return openError != 0 ? openError : TACTILE_ERR_TIMEOUT.rawValue
}

// MARK: Controller

@_cdecl("tactile_controller_retain")
public func tactile_controller_retain(_ p: OpaquePointer?) {
    guard let p else { return }
    _ = Unmanaged<ControllerBox>.fromOpaque(UnsafeRawPointer(p)).retain()
}

@_cdecl("tactile_controller_release")
public func tactile_controller_release(_ p: OpaquePointer?) {
    guard let p else { return }
    Unmanaged<ControllerBox>.fromOpaque(UnsafeRawPointer(p)).release()
}

@_cdecl("tactile_controller_get_info")
public func tactile_controller_get_info(_ p: OpaquePointer?, _ out: UnsafeMutablePointer<tactile_controller_info>?) -> Int32 {
    guard let b = controller(p), let out else { return EINVAL }
    let c = b.controller
    let (address, fw, features) = blocking { () -> (String, FirmwareInfo?, FeatureSet?) in
        (await c.address?.description ?? "", await c.firmware, await c.connection?.features)
    }
    var i = tactile_controller_info()
    i.model = Int32(c.model == .dualSenseEdge ? TACTILE_MODEL_DUALSENSE_EDGE.rawValue : TACTILE_MODEL_DUALSENSE.rawValue)
    i.transport = Int32(c.transport == .usb ? TACTILE_TRANSPORT_USB.rawValue : TACTILE_TRANSPORT_BLUETOOTH.rawValue)
    withUnsafeMutableBytes(of: &i.address) { dst in
        let bytes = Array(address.utf8.prefix(dst.count - 1))
        for (k, v) in bytes.enumerated() { dst[k] = v }
        dst[bytes.count] = 0
    }
    i.firmware_version = fw?.firmwareVersion ?? 0
    i.hardware_version = fw?.hardwareVersion ?? 0
    i.update_version = fw?.updateVersion ?? 0
    i.vibration_v2 = features?.vibrationV2 == true ? 1 : 0
    i.connected = b.isLive ? 1 : 0
    copyOut(i, to: out)
    return OK
}

@_cdecl("tactile_controller_get_input")
public func tactile_controller_get_input(_ p: OpaquePointer?, _ out: UnsafeMutablePointer<tactile_input_state>?) -> Int32 {
    guard let b = controller(p), let out else { return EINVAL }
    guard b.isLive, let s = b.input() else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    copyOut(s, to: out)
    return OK
}

@_cdecl("tactile_controller_set_lightbar")
public func tactile_controller_set_lightbar(_ p: OpaquePointer?, _ r: UInt8, _ g: UInt8, _ bl: UInt8) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in try await c.setLightbar(LightbarColor(red: r, green: g, blue: bl)) }
}

@_cdecl("tactile_controller_set_player_leds")
public func tactile_controller_set_player_leds(_ p: OpaquePointer?, _ mask: UInt8) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in try await c.setPlayerLEDs(PlayerLEDs(rawValue: mask)) }
}

@_cdecl("tactile_controller_set_mute_led")
public func tactile_controller_set_mute_led(_ p: OpaquePointer?, _ mode: Int32) -> Int32 {
    guard let b = controller(p), let m = MuteLED(rawValue: UInt8(clamping: mode)), mode >= 0 else { return EINVAL }
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in try await c.setMuteLED(m) }
}

@_cdecl("tactile_controller_set_rumble")
public func tactile_controller_set_rumble(_ p: OpaquePointer?, _ l: UInt8, _ r: UInt8) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in try await c.setRumble(Rumble(left: l, right: r)) }
}

@_cdecl("tactile_controller_set_trigger")
public func tactile_controller_set_trigger(_ p: OpaquePointer?, _ side: Int32, _ effect: UnsafePointer<tactile_trigger_effect>?) -> Int32 {
    guard let b = controller(p), let effect else { return EINVAL }
    guard side == Int32(TACTILE_TRIGGER_LEFT.rawValue) || side == Int32(TACTILE_TRIGGER_RIGHT.rawValue) else { return EINVAL }
    let bytes = withUnsafeBytes(of: effect.pointee.bytes) { Array($0) }
    let e = TriggerEffect(rawBytes: bytes)
    let s: TriggerSide = side == Int32(TACTILE_TRIGGER_LEFT.rawValue) ? .left : .right
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in try await c.setTrigger(s, e) }
}

@_cdecl("tactile_controller_neutralize")
public func tactile_controller_neutralize(_ p: OpaquePointer?) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    let c = b.controller
    return b.enqueue { () async throws(TransportError) in await c.neutralize() }
}

@_cdecl("tactile_controller_last_error")
public func tactile_controller_last_error(_ p: OpaquePointer?) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    return b.lastError.value.exchange(0, ordering: .relaxed)
}

// MARK: Trigger builders

@_cdecl("tactile_trigger_off")
public func tactile_trigger_off(_ out: UnsafeMutablePointer<tactile_trigger_effect>?) {
    _ = triggerOut({ .off }, out)
}

@_cdecl("tactile_trigger_feedback")
public func tactile_trigger_feedback(_ pos: Int32, _ str: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .feedback(position: Int(pos), strength: Int(str)) }, out)
}

@_cdecl("tactile_trigger_weapon")
public func tactile_trigger_weapon(_ s: Int32, _ e: Int32, _ str: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .weapon(start: Int(s), end: Int(e), strength: Int(str)) }, out)
}

@_cdecl("tactile_trigger_vibration")
public func tactile_trigger_vibration(_ pos: Int32, _ amp: Int32, _ freq: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .vibration(position: Int(pos), amplitude: Int(amp), frequency: Int(freq)) }, out)
}

@_cdecl("tactile_trigger_slope_feedback")
public func tactile_trigger_slope_feedback(_ sp: Int32, _ ep: Int32, _ ss: Int32, _ es: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .slopeFeedback(startPosition: Int(sp), endPosition: Int(ep), startStrength: Int(ss), endStrength: Int(es)) }, out)
}

@_cdecl("tactile_trigger_multiple_position_feedback")
public func tactile_trigger_multiple_position_feedback(_ strengths: UnsafePointer<Int32>?, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    guard let strengths else { return EINVAL }
    let a = (0..<10).map { Int(strengths[$0]) }
    return triggerOut({ try .multiplePositionFeedback(strengths: a) }, out)
}

@_cdecl("tactile_trigger_multiple_position_vibration")
public func tactile_trigger_multiple_position_vibration(_ freq: Int32, _ amps: UnsafePointer<Int32>?, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    guard let amps else { return EINVAL }
    let a = (0..<10).map { Int(amps[$0]) }
    return triggerOut({ try .multiplePositionVibration(frequency: Int(freq), amplitudes: a) }, out)
}

@_cdecl("tactile_trigger_bow")
public func tactile_trigger_bow(_ s: Int32, _ e: Int32, _ str: Int32, _ snap: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .bow(start: Int(s), end: Int(e), strength: Int(str), snapForce: Int(snap)) }, out)
}

@_cdecl("tactile_trigger_galloping")
public func tactile_trigger_galloping(_ s: Int32, _ e: Int32, _ f1: Int32, _ f2: Int32, _ freq: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .galloping(start: Int(s), end: Int(e), firstFoot: Int(f1), secondFoot: Int(f2), frequency: Int(freq)) }, out)
}

@_cdecl("tactile_trigger_machine")
public func tactile_trigger_machine(_ s: Int32, _ e: Int32, _ a: Int32, _ bb: Int32, _ freq: Int32, _ period: Int32, _ out: UnsafeMutablePointer<tactile_trigger_effect>?) -> Int32 {
    triggerOut({ try .machine(start: Int(s), end: Int(e), amplitudeA: Int(a), amplitudeB: Int(bb), frequency: Int(freq), period: Int(period)) }, out)
}

// MARK: Haptics

@_cdecl("tactile_haptics_start")
public func tactile_haptics_start(_ p: OpaquePointer?) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    guard !b.isInvalidated else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    let c = b.controller
    return blocking { () -> Int32 in
        do throws(TransportError) { try await c.startHaptics(); return OK } catch { return code(error) }
    }
}

@_cdecl("tactile_haptics_stop")
public func tactile_haptics_stop(_ p: OpaquePointer?) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    // After context teardown the controller is closed and its pump stopped.
    guard !b.isInvalidated else { return OK }
    let c = b.controller
    blocking { await c.stopHaptics() }
    return OK
}

@_cdecl("tactile_haptics_play")
public func tactile_haptics_play(_ p: OpaquePointer?, _ effect: Int32, _ intensity: Float, _ side: Int32) -> Int32 {
    guard let b = controller(p) else { return EINVAL }
    let a = max(0, min(intensity, 1))
    let e: HapticEffect
    switch UInt32(bitPattern: effect) {
    case TACTILE_HAPTIC_CLICK.rawValue: e = .click(intensity: a)
    case TACTILE_HAPTIC_DETENT.rawValue: e = .detent(intensity: a)
    case TACTILE_HAPTIC_TEXTURE.rawValue: e = .texture(intensity: a)
    case TACTILE_HAPTIC_IMPACT.rawValue: e = .impact(intensity: a)
    default: return EINVAL
    }
    let s: HapticSide = switch UInt32(bitPattern: side) {
    case TACTILE_HAPTIC_LEFT.rawValue: .left
    case TACTILE_HAPTIC_RIGHT.rawValue: .right
    default: .both
    }
    guard !b.isInvalidated else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    let c = b.controller
    if c.hapticsRunning {
        c.haptics.play(e, side: s)
        return OK
    }
    return b.enqueue { () async throws(TransportError) in try await c.play(e, side: s) }
}

@_cdecl("tactile_haptics_write_pcm")
public func tactile_haptics_write_pcm(_ p: OpaquePointer?, _ samples: UnsafePointer<Float>?, _ frames: Int32, _ channels: Int32, _ rate: Double) -> Int32 {
    guard let b = controller(p), let samples, frames >= 0, channels > 0, rate > 0 else { return EINVAL }
    guard b.isLive else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    let arr = Array(UnsafeBufferPointer(start: samples, count: Int(frames) * Int(channels)))
    return b.writePCM(arr, channels: Int(channels), rate: rate)
}

@_cdecl("tactile_haptics_get_metrics")
public func tactile_haptics_get_metrics(_ p: OpaquePointer?, _ out: UnsafeMutablePointer<tactile_haptics_metrics>?) -> Int32 {
    guard let b = controller(p), let out else { return EINVAL }
    guard b.isLive else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
    var r = tactile_haptics_metrics()
    // Connected but haptics stopped: no pump, so every metric is zero.
    guard let m = b.controller.hapticsMetrics() else {
        copyOut(r, to: out)
        return OK
    }
    r.reports_sent = UInt64(m.reportsSent)
    r.reports_dropped = UInt64(m.reportsDropped)
    r.underrun_ticks = UInt64(m.underrunTicks)
    r.wake_lateness_p99_us = m.wakeLatenessP99Us
    r.tick_interval_stddev_us = m.tickIntervalStdDevUs
    r.send_latency_mean_us = m.sendLatencyMeanUs
    r.send_latency_p99_us = m.sendLatencyP99Us
    r.pump_cpu_percent = m.pumpCPUPercent
    copyOut(r, to: out)
    return OK
}
