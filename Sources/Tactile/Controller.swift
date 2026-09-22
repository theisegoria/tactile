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
        var pump: HapticsPump?
        var sink: ConnectionHapticsSink?
        var rumble: Rumble = .off
        /// Kept after a disconnect so owned state can be re-applied on reconnect.
        var lastConnection: DeviceConnection?
        /// Haptics were running when the link dropped; restart on reconnect.
        var hapticsWanted = false
    }
    private let state: Mutex<State>
    /// Haptics mixer (always available; only audible while haptics are started).
    public let haptics: HapticsMixer

    init(connection: DeviceConnection, info: DeviceInfo, id: String) {
        self.id = id
        model = info.model
        state = Mutex(State(connection: connection, info: info))
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

    func replaceConnection(_ c: DeviceConnection, info: DeviceInfo) async {
        let (old, pumpWasRunning) = state.withLock { s -> (DeviceConnection?, Bool) in
            let o = s.connection ?? s.lastConnection
            s.connection = c
            s.lastConnection = nil
            s.info = info
            return (o, s.hapticsWanted)
        }
        let previous = await old?.ownedOutput
        if let previous, previous != OutputState() {
            try? await c.apply(previous)
        }
        if pumpWasRunning {
            try? await startHaptics()
        }
    }

    func connectionLost() {
        let wanted = hapticsRunning
        stopHapticsPump()
        state.withLock { s in
            s.hapticsWanted = wanted
            s.lastConnection = s.connection
            s.connection = nil
        }
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
        let pumping = state.withLock { s -> Bool in
            s.rumble = r
            return s.pump?.isRunning ?? false
        }
        if pumping {
            haptics.setRumble(r)
        } else {
            try await apply(OutputState(rumble: r))
        }
    }

    /// Returns to neutral: triggers off, rumble off, lightbar restored.
    public func neutralize() async {
        haptics.stopAll()
        await connection?.neutralize()
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
    /// anything is playing). Legacy rumble moves onto the voice coils.
    public func startHaptics(framing: HapticsFraming = .documented) async throws(TransportError) {
        let c = try conn()
        guard transport == .bluetooth else {
            throw .notSupported("audio haptics over USB go through the controller's USB audio interface")
        }
        let (pump, rumble): (HapticsPump?, Rumble) = state.withLock { s in
            guard s.pump == nil else { return (nil, s.rumble) }
            let sink = ConnectionHapticsSink(connection: c)
            let p = HapticsPump(mixer: haptics, sink: sink, framing: framing)
            s.sink = sink
            s.pump = p
            return (p, s.rumble)
        }
        guard let pump else { return }
        await c.setRumbleSuppressed(true)
        haptics.setRumble(rumble)
        pump.start()
    }

    public func stopHaptics() async {
        stopHapticsPump()
        state.withLock { $0.hapticsWanted = false }
        haptics.stopAll()
        let r = state.withLock { $0.rumble }
        await connection?.setRumbleSuppressed(false)
        try? await connection?.apply(OutputState(rumble: r))
    }

    private func stopHapticsPump() {
        state.withLock { s in
            s.pump?.stop()
            s.sink?.close()
            s.pump = nil
            s.sink = nil
        }
    }

    public var hapticsRunning: Bool { state.withLock { $0.pump?.isRunning ?? false } }

    /// Plays a parametric effect (starts the pump if needed).
    public func play(_ effect: HapticEffect, side: HapticSide = .both) async throws(TransportError) {
        if !hapticsRunning { try await startHaptics() }
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

    /// Closes the connection after restoring neutral output.
    public func close() async {
        stopHapticsPump()
        haptics.stopAll()
        await connection?.close()
    }
}
