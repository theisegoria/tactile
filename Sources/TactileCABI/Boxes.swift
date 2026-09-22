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
    /// Set once the owning context is destroyed: the handle stays safe to
    /// release, but every operation reports TACTILE_ERR_NOT_CONNECTED.
    private let invalidatedFlag = Atomic<Bool>(false)

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

    var isInvalidated: Bool { invalidatedFlag.load(ordering: .acquiring) }

    /// Usable for input and output: not invalidated and currently connected.
    var isLive: Bool { !isInvalidated && controller.isConnected }

    /// Called by context teardown. Refuses further operations and ends the op
    /// queue; returns the op task so the caller can wait for ops that were
    /// already queued to finish before the controller is neutralised.
    func invalidate() -> Task<Void, Never> {
        invalidatedFlag.store(true, ordering: .releasing)
        ops.finish()
        return opTask
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
        guard isLive else { return TACTILE_ERR_NOT_CONNECTED.rawValue }
        // After invalidate() the continuation is finished and the yield is
        // dropped; report that instead of claiming success.
        if case .terminated = ops.yield(op) { return TACTILE_ERR_NOT_CONNECTED.rawValue }
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

    /// Feeds PCM to the haptics stream. Nothing is queued while haptics are
    /// stopped (returns 0): no pump is consuming the ring, and frames buffered
    /// now would otherwise play, stale, whenever haptics start later.
    func writePCM(_ samples: [Float], channels: Int, rate: Double) -> Int32 {
        pcm.withLock { p in
            let mixer = controller.haptics
            guard controller.hapticsRunning else {
                // Forget resampler history too, so a later start begins clean.
                p = nil
                return 0
            }
            if p == nil || p?.inputRate != rate { p = PCMInput(mixer: mixer, inputRate: rate) }
            let n = Int32(p?.feed(interleaved: samples, channelCount: channels) ?? 0)
            // The pump may have stopped between the check and the write. Its
            // stop already requested a flush; request another so these frames
            // are discarded by the next pump instead of playing late.
            if !controller.hapticsRunning {
                mixer.stream.requestClear()
                p = nil
            }
            return n
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
    /// The callback and the teardown flag share one lock, and blocks are only
    /// enqueued while holding it, so once `closed` is set no new block can
    /// appear on `callbackQueue` and a drain really is final.
    private struct Dispatch {
        var callback: Callback?
        var closed = false
    }
    private let dispatch = Mutex(Dispatch())
    private var eventTask: Task<Void, Never>?
    /// Callbacks run here, off Swift's cooperative pool, so a host may call
    /// briefly-blocking entry points (get_info, haptics_start) from a callback.
    private let callbackQueue = DispatchQueue(label: "dev.tactile.callbacks")
    private let onCallbackQueue = DispatchSpecificKey<Bool>()
    /// Most recent controller open failure (a tactile_result), 0 if none.
    /// Reported by wait_for_controller when no controller shows up.
    let lastOpenError = Atomic<Int32>(0)

    init(options: ConnectionOptions) {
        manager = ControllerManager(options: options)
        callbackQueue.setSpecific(key: onCallbackQueue, value: true)
        let events = manager.events()
        eventTask = Task.detached { [weak self] in
            for await e in events { self?.handle(e) }
        }
    }

    private var isOnCallbackQueue: Bool { DispatchQueue.getSpecific(key: onCallbackQueue) == true }

    /// Waits for every callback already queued (or running) to finish. From
    /// inside a callback that would deadlock; there the caller's own callback
    /// is the only one running, and later blocks already see the new state.
    private func drainCallbacks() {
        guard !isOnCallbackQueue else { return }
        callbackQueue.sync {}
    }

    /// Replaces the callback. When called from outside a callback, returns
    /// only after any invocation of the previous callback has finished; the
    /// previous fn/user_data are never called again after that.
    func setCallback(_ cb: tactile_event_callback?, _ user: UnsafeMutableRawPointer?) {
        let value = cb.map { Callback(fn: $0, user: user) }
        let changed = dispatch.withLock { d -> Bool in
            guard !d.closed else { return false }
            d.callback = value
            return true
        }
        if changed { drainCallbacks() }
    }

    private func handle(_ e: ControllerEvent) {
        let (c, kind): (Controller, tactile_event)
        switch e {
        case .connected(let x): (c, kind) = (x, TACTILE_EVENT_CONNECTED)
        case .reconnected(let x): (c, kind) = (x, TACTILE_EVENT_RECONNECTED)
        case .disconnected(let x): (c, kind) = (x, TACTILE_EVENT_DISCONNECTED)
        case .failed(_, let error):
            lastOpenError.store(code(error), ordering: .relaxed)
            return
        }
        if dispatch.withLock({ $0.closed }) { return }
        let box = boxes.withLock { b -> ControllerBox in
            if let existing = b[c.id] { return existing }
            let nb = ControllerBox(c)
            b[c.id] = nb
            order.withLock { $0.append(c.id) }
            return nb
        }
        if kind == TACTILE_EVENT_RECONNECTED { box.restartInput() }
        let event = Int32(kind.rawValue)
        dispatch.withLock { d in
            guard !d.closed, d.callback != nil else { return }
            let handle = Unmanaged.passRetained(box)
            callbackQueue.async { [weak self] in
                defer { handle.release() }
                // Looked up when the block runs, not when it was queued, so a
                // replaced or removed callback is never invoked afterwards.
                guard let cb = self?.dispatch.withLock({ $0.closed ? nil : $0.callback }) else { return }
                cb.fn(cb.user, OpaquePointer(handle.toOpaque()), event)
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
        return all.first { $0.isLive }
    }

    /// Teardown for tactile_context_destroy. After it returns no callback is
    /// running or will run, every handle refuses further operations, ops that
    /// were already queued have finished, and every controller is neutral and
    /// closed.
    func shutdown() {
        dispatch.withLock { d in
            d.closed = true
            d.callback = nil
        }
        eventTask?.cancel()
        drainCallbacks()
        let all = boxes.withLock { Array($0.values) }
        let opTasks = all.map { $0.invalidate() }
        let m = manager
        blocking {
            // Queued ops finish (or fail) before the neutral report, so none
            // can land after it.
            for t in opTasks { await t.value }
            await m.shutdown()
        }
    }
}
