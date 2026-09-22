import Foundation
import Synchronization
public import TactileCore
public import TactileTransport
public import TactileHaptics

/// Which adaptive trigger.
public enum TriggerSide: String, Sendable, CaseIterable {
    case left, right
}

/// A connected (or temporarily disconnected) controller. The object survives
/// reconnects: owned output state is re-applied automatically when the same
/// controller (same Bluetooth address) comes back.
public final class Controller: Sendable, Identifiable, CustomStringConvertible {
    public let id: String
    public let model: ControllerModel

    private struct State {
        var connection: DeviceConnection?
        var info: DeviceInfo
        /// HID device ID of `connection`; nil while disconnected or closed.
        /// Removals of any other device instance must not touch this controller.
        var liveDeviceID: UInt64?
        var pump: HapticsPump?
        var sink: ConnectionHapticsSink?
        var rumble: Rumble = .off
        /// The framing of the last `startHaptics`, reused by reconnects and `play`.
        var framing: HapticsFraming = .documented
        /// Kept after a disconnect so owned state can be re-applied on reconnect.
        var lastConnection: DeviceConnection?
        /// Haptics were started and not stopped since; restart on reconnect.
        var hapticsWanted = false
    }
    private let state: Mutex<State>
    /// Serialises everything that changes haptics ownership or rumble routing
    /// (start, stop, setRumble, neutralize, reconnect, close). Each of those
    /// awaits the connection, and interleaving them would let a stale rumble
    /// suppression, rumble value or pump win.
    private let gate = AsyncGate()
    /// Haptics mixer (always available; only audible while haptics are started).
    public let haptics: HapticsMixer

    init(connection: DeviceConnection, info: DeviceInfo, id: String) {
        self.id = id
        model = info.model
        state = Mutex(State(connection: connection, info: info, liveDeviceID: info.deviceID))
        haptics = HapticsMixer()
    }

    public var description: String { "\(model.displayName) \(id)" }

    public var connection: DeviceConnection? { state.withLock { $0.connection } }
    public var info: DeviceInfo { state.withLock { $0.info } }
    public var transport: Transport { info.transport }
    public var isConnected: Bool { connection != nil }

    private func conn() throws(TransportError) -> DeviceConnection {
        guard let c = connection else { throw .deviceUnavailable }
        return c
    }

    // MARK: Reconnect plumbing

    /// Installs `c` as the live connection and re-applies owned state to it. If
    /// another connection was still installed, its pump is stopped and it is
    /// closed first, so nothing keeps driving the old instance.
    func replaceConnection(_ c: DeviceConnection, info: DeviceInfo) async {
        await gate.run {
            let (liveOld, lastOld, pump, sink) = state.withLock { s in
                let r = (s.connection, s.lastConnection, s.pump, s.sink)
                s.pump = nil
                s.sink = nil
                s.connection = c
                s.liveDeviceID = info.deviceID
                s.lastConnection = nil
                s.info = info
                return r
            }
            stopPump(pump, sink)
            let old = liveOld ?? lastOld
            var previous = await old?.ownedOutput
            let (wanted, framing) = state.withLock { ($0.hapticsWanted, $0.framing) }
            // With haptics wanted, rumble belongs to the mixer: the connection's
            // copy predates the pump and must not go out on 0x31.
            if wanted { previous?.rumble = nil }
            // Close a still-installed old instance before writing to the new one:
            // its neutral report reaches the same physical controller.
            if let liveOld, liveOld !== c { await liveOld.close() }
            if let previous, previous != OutputState() {
                try? await c.apply(previous)
            }
            if wanted {
                try? await startHapticsLocked(framing: framing)
                // Haptics could not start on this transport: rumble goes back to 0x31.
                let (running, rumble) = state.withLock { ($0.pump != nil, $0.rumble) }
                if !running, rumble != .off { try? await c.apply(OutputState(rumble: rumble)) }
            }
        }
    }

    /// The HID device ID of the live connection, if any.
    var liveDeviceID: UInt64? { state.withLock { $0.liveDeviceID } }

    /// Marks the controller disconnected if `deviceID` is its live connection.
    /// Returns false (and changes nothing) for any other device instance.
    func connectionLost(deviceID: UInt64) -> Bool {
        let taken = state.withLock { s -> (HapticsPump?, ConnectionHapticsSink?)? in
            guard s.connection != nil, s.liveDeviceID == deviceID else { return nil }
            let r = (s.pump, s.sink)
            s.pump = nil
            s.sink = nil
            s.lastConnection = s.connection
            s.connection = nil
            s.liveDeviceID = nil
            return r
        }
        guard let taken else { return false }
        stopPump(taken.0, taken.1)
        return true
    }

    // MARK: Output

    public func apply(_ patch: OutputState) async throws(TransportError) {
        try await conn().apply(patch)
    }

    public func setLightbar(_ color: LightbarColor) async throws(TransportError) {
        try await apply(OutputState(lightbar: color))
    }

    public func setPlayerLEDs(_ leds: PlayerLEDs, brightness: LEDBrightness? = nil) async throws(TransportError) {
        try await apply(OutputState(playerLEDs: leds, playerLEDBrightness: brightness))
    }

    public func setMuteLED(_ led: MuteLED) async throws(TransportError) {
        try await apply(OutputState(muteLED: led))
    }

    public func setTrigger(_ side: TriggerSide, _ effect: TriggerEffect) async throws(TransportError) {
        try await apply(side == .left ? OutputState(leftTrigger: effect) : OutputState(rightTrigger: effect))
    }

    /// Rumble. While audio haptics are running, rumble is emulated on the voice
    /// coils by the haptics mixer instead of via report 0x31 (arbitration policy,
    /// docs/Haptics.md).
    public func setRumble(_ r: Rumble) async throws(TransportError) {
        try await gate.run { () async throws(TransportError) in
            // Routed on "haptics own rumble" (a pump is installed), decided under
            // the same lock that records the value, so start/stop always pick
            // up the latest rumble.
            let (pumping, c) = state.withLock { s -> (Bool, DeviceConnection?) in
                s.rumble = r
                return (s.pump != nil, s.connection)
            }
            if pumping {
                haptics.setRumble(r)
            } else {
                guard let c else { throw .deviceUnavailable }
                try await c.apply(OutputState(rumble: r))
            }
        }
    }

    /// Returns to neutral: triggers off, rumble off, lightbar restored.
    public func neutralize() async {
        await gate.run {
            // Forget the stored rumble too, or a later stopHaptics/startHaptics
            // would bring it back.
            let c = state.withLock { s -> DeviceConnection? in
                s.rumble = .off
                return s.connection
            }
            haptics.stopAll()
            await c?.neutralize()
        }
    }

    // MARK: Input

    /// Decoded input events. The stream ends when the controller disconnects;
    /// call again after a reconnect.
    public func inputEvents() async -> AsyncStream<InputEvent> {
        guard let c = connection else { return AsyncStream { $0.finish() } }
        return await c.inputEvents()
    }

    public var lastInput: InputState? {
        get async { await connection?.lastInput }
    }

    // MARK: Haptics

    /// Starts the Bluetooth audio-haptics pump (report 0x32 every 10.67 ms while
    /// anything is playing). Legacy rumble moves onto the voice coils. No-op
    /// while already running; to change `framing`, stop first. The framing is
    /// remembered and reused when haptics restart after a reconnect.
    public func startHaptics(framing: HapticsFraming = .documented) async throws(TransportError) {
        try await gate.run { () async throws(TransportError) in
            try await startHapticsLocked(framing: framing)
        }
    }

    /// Caller holds `gate`.
    private func startHapticsLocked(framing: HapticsFraming) async throws(TransportError) {
        let c = try conn()
        guard transport == .bluetooth else {
            throw .notSupported("audio haptics over USB go through the controller's USB audio interface")
        }
        let pump = state.withLock { s -> HapticsPump? in
            guard s.pump == nil, s.connection === c else { return nil }
            let sink = ConnectionHapticsSink(connection: c)
            let p = HapticsPump(mixer: haptics, sink: sink, framing: framing)
            s.sink = sink
            s.pump = p
            s.framing = framing
            s.hapticsWanted = true
            return p
        }
        guard let pump else { return }
        await c.setRumbleSuppressed(true)
        // Start only if the pump is still the installed one: the synchronous
        // connectionLost() may have taken it during the await, and a pump
        // started after that would run untracked forever. The latest rumble is
        // read here, not before the await, so a concurrent value is not lost.
        let started = state.withLock { s -> Bool in
            guard s.pump === pump else { return false }
            haptics.setRumble(s.rumble)
            pump.start()
            return true
        }
        if !started {
            // The connection was lost meanwhile; leave it unsuppressed.
            await c.setRumbleSuppressed(false)
        }
    }

    public func stopHaptics() async {
        await gate.run {
            let (pump, sink, c) = state.withLock { s in
                let r = (s.pump, s.sink, s.connection)
                s.pump = nil
                s.sink = nil
                s.hapticsWanted = false
                return r
            }
            stopPump(pump, sink)
            haptics.stopAll()
            guard let c else { return }
            await c.setRumbleSuppressed(false)
            // setRumble cannot interleave (gate), so this is the latest value.
            let r = state.withLock { $0.rumble }
            try? await c.apply(OutputState(rumble: r))
        }
    }

    /// Stops a pump taken out of state (outside the lock: `stop` waits for the
    /// pump thread's last pass) and closes its sink.
    private func stopPump(_ pump: HapticsPump?, _ sink: ConnectionHapticsSink?) {
        pump?.stop()
        sink?.close()
    }

    public var hapticsRunning: Bool { state.withLock { $0.pump?.isRunning ?? false } }

    /// Plays a parametric effect (starts the pump if needed, with the framing
    /// of the last `startHaptics`).
    public func play(_ effect: HapticEffect, side: HapticSide = .both) async throws(TransportError) {
        try await gate.run { () async throws(TransportError) in
            let (installed, framing) = state.withLock { ($0.pump != nil, $0.framing) }
            if !installed { try await startHapticsLocked(framing: framing) }
        }
        haptics.play(effect, side: side)
    }

    public func hapticsMetrics() -> HapticsMetrics? {
        state.withLock { $0.pump?.metrics() }
    }

    // MARK: Diagnostics

    public var firmware: FirmwareInfo? { get async { await connection?.firmware } }
    public var calibration: IMUCalibration? { get async { await connection?.calibration } }
    public var address: MACAddress? { get async { await connection?.address } }
    public func conflicts() -> ConflictReport? { connection?.conflicts() }

    /// Closes the connection after restoring neutral output. Afterwards the
    /// controller reports `isConnected == false`; it is only used again if the
    /// manager re-discovers the device (with nothing to re-apply).
    public func close() async {
        await gate.run {
            let (pump, sink, c) = state.withLock { s in
                let r = (s.pump, s.sink, s.connection)
                s.pump = nil
                s.sink = nil
                s.connection = nil
                s.lastConnection = nil
                s.liveDeviceID = nil
                s.hapticsWanted = false
                s.rumble = .off
                return r
            }
            stopPump(pump, sink)
            haptics.stopAll()
            await c?.close()
        }
    }
}
