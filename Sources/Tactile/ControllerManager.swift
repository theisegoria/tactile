import Foundation
import Synchronization
public import TactileTransport

/// Lifecycle events.
public enum ControllerEvent: Sendable {
    case connected(Controller)
    /// The same controller came back; owned output state has been re-applied.
    case reconnected(Controller)
    case disconnected(Controller)
    /// A controller was found but could not be opened.
    case failed(DeviceInfo, TransportError)
}

/// Discovers controllers, opens them, and keeps `Controller` objects stable
/// across disconnects and reconnects (keyed by Bluetooth address).
///
/// The same physical controller can appear as two HID devices at once (for
/// example Bluetooth plus a USB cable), or a new instance can match before the
/// old one's removal arrives. The live connection is kept; a second live
/// instance waits as a standby and takes over when the live one is removed.
public final class ControllerManager: Sendable {
    public let options: ConnectionOptions
    private let discovery = DeviceDiscovery()
    private struct Standby {
        var connection: DeviceConnection
        var info: DeviceInfo
    }
    private struct State {
        var byKey: [String: Controller] = [:]
        var keyByDeviceID: [UInt64: String] = [:]
        var standby: [String: Standby] = [:]
        var task: Task<Void, Never>?
        var continuations: [UUID: AsyncStream<ControllerEvent>.Continuation] = [:]
        /// Bumped by `shutdown()`; an open that started before it is discarded.
        var generation: UInt64 = 0
    }
    private let state = Mutex(State())

    public init(options: ConnectionOptions = .init()) {
        self.options = options
    }

    deinit { state.withLock { $0.task?.cancel() } }

    /// All controllers seen since the last `shutdown()`, connected or not.
    public var controllers: [Controller] { state.withLock { Array($0.byKey.values) } }

    /// Starts discovery (idempotent) and returns a stream of lifecycle events.
    /// Already-connected controllers are replayed as `.connected`.
    public func events() -> AsyncStream<ControllerEvent> {
        let (stream, cont) = AsyncStream<ControllerEvent>.makeStream()
        let id = UUID()
        cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        // Registration, replay and every emitted event share one lock, so each
        // controller is announced exactly once and in order.
        state.withLock { s in
            s.continuations[id] = cont
            for c in s.byKey.values where c.isConnected { cont.yield(.connected(c)) }
        }
        start()
        return stream
    }

    /// Convenience: a stream of newly connected controllers.
    public func connectedControllers() -> AsyncStream<Controller> {
        let events = self.events()
        return AsyncStream { cont in
            let t = Task {
                for await e in events { if case .connected(let c) = e { cont.yield(c) } }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Waits for the first controller, up to `timeout`.
    public func firstController(timeout: Duration = .seconds(5)) async -> Controller? {
        let events = self.events()
        return await withTaskGroup(of: Controller?.self) { g in
            g.addTask {
                for await e in events {
                    if case .connected(let c) = e { return c }
                }
                return nil
            }
            g.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r
        }
    }

    public func start() {
        state.withLock { s in
            guard s.task == nil else { return }
            s.task = Task { [weak self] in await self?.run() }
        }
    }

    /// Closes every controller (restoring neutral output) and stops discovery.
    /// Waits for the discovery task to end, so no controller opened concurrently
    /// is left behind. Event streams end; a later `events()` starts a fresh
    /// session in which controllers are announced again as new objects.
    public func shutdown() async {
        let (all, standby, task) = state.withLock { s in
            s.generation &+= 1
            let r = (Array(s.byKey.values), Array(s.standby.values), s.task)
            s.byKey.removeAll()
            s.keyByDeviceID.removeAll()
            s.standby.removeAll()
            s.task = nil
            for c in s.continuations.values { c.finish() }
            s.continuations.removeAll()
            return r
        }
        task?.cancel()
        await task?.value
        for c in all { await c.close() }
        for sb in standby { await sb.connection.close() }
    }

    private func emit(_ e: ControllerEvent) {
        state.withLock { s in
            for c in s.continuations.values { c.yield(e) }
        }
    }

    private func run() async {
        do {
            for try await event in discovery.events() {
                switch event {
                case .connected(let info, let ref):
                    await handleConnect(info, ref)
                case .disconnected(let deviceID):
                    await handleDisconnect(deviceID)
                }
            }
        } catch {}
    }

    private enum ConnectOutcome {
        case discard
        case created
        case standby(live: DeviceConnection, replaced: DeviceConnection?)
        case replace(Controller)
    }

    private func handleConnect(_ info: DeviceInfo, _ ref: HIDDeviceClientReference) async {
        let generation = state.withLock { $0.generation }
        let conn: DeviceConnection
        do {
            conn = try await DeviceConnection.open(ref, info: info, options: options)
        } catch {
            emit(.failed(info, error))
            return
        }
        let key = await conn.address?.description ?? info.serialNumber ?? "id-\(info.deviceID)"
        let current = state.withLock { $0.byKey[key]?.connection }
        let currentAlive = await current?.isOpen ?? false
        let outcome = state.withLock { s -> ConnectOutcome in
            // shutdown() ran while this device was being opened.
            guard s.generation == generation else { return .discard }
            s.keyByDeviceID[info.deviceID] = key
            guard let c = s.byKey[key] else {
                let c = Controller(connection: conn, info: info, id: key)
                s.byKey[key] = c
                // Announced under the lock that inserted it, so a concurrent
                // events() sees it either in its replay or here, never both.
                for k in s.continuations.values { k.yield(.connected(c)) }
                return .created
            }
            // The controller is still live on another instance (e.g. Bluetooth
            // plus USB): keep that one and hold this one in reserve.
            if currentAlive, let live = current, c.connection === live {
                let old = s.standby.updateValue(Standby(connection: conn, info: info), forKey: key)
                return .standby(live: live, replaced: old?.connection)
            }
            return .replace(c)
        }
        switch outcome {
        case .discard:
            await conn.close()
        case .created:
            break
        case .standby(let live, let replaced):
            await replaced?.close()
            // Opening (or closing) another instance may have sent a neutral
            // report to the same physical controller: restore the live state
            // (through apply, so the crash journal is marked dirty again).
            try? await live.apply(OutputState())
        case .replace(let c):
            await c.replaceConnection(conn, info: info)
            emit(.reconnected(c))
        }
    }

    private enum DisconnectOutcome {
        case ignore
        case dropStandby(DeviceConnection)
        case lost(Controller, Standby?)
    }

    private func handleDisconnect(_ deviceID: UInt64) async {
        let outcome = state.withLock { s -> DisconnectOutcome in
            guard let key = s.keyByDeviceID.removeValue(forKey: deviceID) else { return .ignore }
            if let sb = s.standby[key], sb.info.deviceID == deviceID {
                s.standby[key] = nil
                return .dropStandby(sb.connection)
            }
            // Only the removal of the live instance disconnects the controller;
            // a late removal of an instance it already replaced is ignored.
            guard let c = s.byKey[key], c.liveDeviceID == deviceID else { return .ignore }
            return .lost(c, s.standby.removeValue(forKey: key))
        }
        switch outcome {
        case .ignore:
            return
        case .dropStandby(let conn):
            await conn.close()
        case .lost(let c, let standby):
            guard c.connectionLost(deviceID: deviceID) else {
                // Closed by the app meanwhile.
                await standby?.connection.close()
                return
            }
            if let standby, await standby.connection.isOpen {
                await c.replaceConnection(standby.connection, info: standby.info)
                emit(.reconnected(c))
            } else {
                await standby?.connection.close()
                emit(.disconnected(c))
            }
        }
    }
}
