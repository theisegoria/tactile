// Swift objects behind the opaque C handles.

import CTactileHeaders
import Foundation
import Synchronization
import Tactile

/// Blocks the calling thread until `body` completes. Only used by C entry
/// points documented as blocking.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let result = Mutex<T?>(nil)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let v = await body()
        result.withLock { $0 = v }
        sem.signal()
    }
    sem.wait()
    return result.withLock { $0 }!
}

func code(_ e: TransportError) -> Int32 {
    switch e {
    case .inputMonitoringDenied: TACTILE_ERR_PERMISSION.rawValue
    case .deviceUnavailable, .closed: TACTILE_ERR_NOT_CONNECTED.rawValue
    case .notSupported: TACTILE_ERR_UNSUPPORTED.rawValue
    case .exclusiveAccessHeldByAnotherProcess: TACTILE_ERR_BUSY.rawValue
    case .timeout: TACTILE_ERR_TIMEOUT.rawValue
    case .ioFailure, .parse: TACTILE_ERR_IO.rawValue
    }
}

final class ErrorCell: Sendable {
    let value = Atomic<Int32>(0)
}

final class ControllerBox: @unchecked Sendable {
    let controller: Controller
    private let latest = Mutex<tactile_input_state?>(nil)
    private let reportCount = Atomic<UInt64>(0)
    let lastError = ErrorCell()
    private let ops: AsyncStream<@Sendable () async throws(TransportError) -> Void>.Continuation
    private let opTask: Task<Void, Never>
    private var inputTask: Task<Void, Never>?
    private let pcm = Mutex<PCMInput?>(nil)

    init(_ c: Controller) {
        controller = c
        let (stream, cont) = AsyncStream<@Sendable () async throws(TransportError) -> Void>.makeStream()
        ops = cont
        let err = lastError
        opTask = Task.detached {
            for await op in stream {
                do throws(TransportError) { try await op() } catch { err.value.store(code(error), ordering: .relaxed) }
            }
        }
        restartInput()
    }

    deinit {
        ops.finish()
        opTask.cancel()
        inputTask?.cancel()
    }

    /// (Re)subscribes to input; called on connect and reconnect.
    func restartInput() {
        inputTask?.cancel()
        let c = controller
        inputTask = Task.detached { [weak self] in
            for await e in await c.inputEvents() {
                self?.store(e)
            }
            self?.latest.withLock { $0 = nil }
        }
    }

    func enqueue(_ op: @escaping @Sendable () async throws(TransportError) -> Void) -> Int32 {
        guard controller.isConnected else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
        ops.yield(op)
        return TACTILE_OK.rawValue
    }

    func input() -> tactile_input_state? { latest.withLock { $0 } }

    private func store(_ e: InputEvent) {
        let n = reportCount.add(1, ordering: .relaxed).newValue
        var s = tactile_input_state()
        s.struct_size = UInt32(MemoryLayout<tactile_input_state>.size)
        let st = e.state
        s.left_x = st.leftStick.x; s.left_y = st.leftStick.y
        s.right_x = st.rightStick.x; s.right_y = st.rightStick.y
        s.l2 = st.l2; s.r2 = st.r2
        s.buttons = st.buttons.rawValue
        if let imu = e.imu {
            s.has_imu = 1
            s.gyro_dps = (imu.gyroDegPerSec.x, imu.gyroDegPerSec.y, imu.gyroDegPerSec.z)
            s.accel_g = (imu.accelG.x, imu.accelG.y, imu.accelG.z)
            s.sensor_timestamp = imu.timestamp
        }
        if st.touchPoints.count == 2 {
            s.has_touch = 1
            let t0 = st.touchPoints[0], t1 = st.touchPoints[1]
            s.touch_active = (t0.active ? 1 : 0, t1.active ? 1 : 0)
            s.touch_id = (t0.id, t1.id)
            s.touch_x = (t0.x, t1.x)
            s.touch_y = (t0.y, t1.y)
        }
        if let b = st.battery {
            s.battery_percent = Int32(b.percent)
            s.battery_charging = switch b.charging {
            case .discharging: 0
            case .charging: 1
            case .full: 2
            default: -1
            }
        } else {
            s.battery_percent = -1
            s.battery_charging = -1
        }
        s.report_count = n
        latest.withLock { $0 = s }
    }

    func writePCM(_ samples: [Float], channels: Int, rate: Double) -> Int32 {
        pcm.withLock { p in
            if p == nil || p?.inputRate != rate { p = PCMInput(mixer: controller.haptics, inputRate: rate) }
            return Int32(p?.feed(interleaved: samples, channelCount: channels) ?? 0)
        }
    }
}

final class ContextBox: @unchecked Sendable {
    let manager: ControllerManager
    private let boxes = Mutex<[String: ControllerBox]>([:])
    private let order = Mutex<[String]>([])
    struct Callback: @unchecked Sendable {
        var fn: tactile_event_callback
        var user: UnsafeMutableRawPointer?
    }
    private let callback = Mutex<Callback?>(nil)
    private var eventTask: Task<Void, Never>?
    /// Callbacks run here, off Swift's cooperative pool, so a host may call
    /// briefly-blocking entry points (get_info, haptics_start) from a callback.
    private let callbackQueue = DispatchQueue(label: "dev.tactile.callbacks")

    init(options: ConnectionOptions) {
        manager = ControllerManager(options: options)
        let events = manager.events()
        eventTask = Task.detached { [weak self] in
            for await e in events { self?.handle(e) }
        }
    }

    func setCallback(_ cb: tactile_event_callback?, _ user: UnsafeMutableRawPointer?) {
        let value = cb.map { Callback(fn: $0, user: user) }
        callback.withLock { $0 = value }
    }

    private func handle(_ e: ControllerEvent) {
        let (c, kind): (Controller, tactile_event)
        switch e {
        case .connected(let x): (c, kind) = (x, TACTILE_EVENT_CONNECTED)
        case .reconnected(let x): (c, kind) = (x, TACTILE_EVENT_RECONNECTED)
        case .disconnected(let x): (c, kind) = (x, TACTILE_EVENT_DISCONNECTED)
        case .failed: return
        }
        let box = boxes.withLock { b -> ControllerBox in
            if let existing = b[c.id] { return existing }
            let nb = ControllerBox(c)
            b[c.id] = nb
            order.withLock { $0.append(c.id) }
            return nb
        }
        if kind == TACTILE_EVENT_RECONNECTED { box.restartInput() }
        if let cb = callback.withLock({ $0 }) {
            let handle = Unmanaged.passRetained(box)
            let event = Int32(kind.rawValue)
            callbackQueue.async {
                cb.fn(cb.user, OpaquePointer(handle.toOpaque()), event)
                handle.release()
            }
        }
    }

    var count: Int { order.withLock { $0.count } }

    func box(at i: Int) -> ControllerBox? {
        let ids = order.withLock { $0 }
        guard i >= 0, i < ids.count else { return nil }
        return boxes.withLock { $0[ids[i]] }
    }

    func firstConnected() -> ControllerBox? {
        let ids = order.withLock { $0 }
        let all = boxes.withLock { b in ids.compactMap { b[$0] } }
        return all.first { $0.controller.isConnected }
    }

    func shutdown() {
        eventTask?.cancel()
        callbackQueue.sync {}  // drain callbacks already queued
        let m = manager
        blocking { await m.shutdown() }
    }
}
