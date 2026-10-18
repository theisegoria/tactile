import Foundation
import Synchronization
public import TactileTransport
import TactileCore

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
    private let discover: @Sendable () -> AsyncThrowingStream<ManagerDiscoveryEvent, any Error>
    private struct Standby {
        var connection: DeviceConnection
        var info: DeviceInfo
    }
    private struct State {
        var byKey: [String: Controller] = [:]
        var keyByDeviceID: [UInt64: String] = [:]
        var standby: [String: Standby] = [:]
        var task: Task<Void, Never>?
        var cleanup: Task<Void, Never>?
        var continuations: [UUID: AsyncStream<ControllerEvent>.Continuation] = [:]
        /// Bumped by `shutdown()`; an open that started before it is discarded.
        var generation: UInt64 = 0
    }
    private let state = Mutex(State())
    /// Serialises registration, replay and emission so each controller is
    /// announced once and in order. Yields happen under this lock, never under
    /// `state`: a stream's onTermination takes `state` while the runtime holds
    /// that task's status lock, and yielding to the same task under `state`
    /// would invert the order and deadlock.
    private let emission = Mutex(())

    public init(options: ConnectionOptions = .init()) {
        self.options = options
        discover = {
            let source = DeviceDiscovery().events()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in source {
                            switch event {
                            case .connected(let info, let reference):
                                continuation.yield(.connected(info, { () async throws(TransportError) in
                                    try await DeviceConnection.open(reference, info: info, options: options)
                                }))
                            case .disconnected(let id): continuation.yield(.disconnected(id))
                            }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    init(options: ConnectionOptions, discover: @escaping @Sendable () -> AsyncThrowingStream<ManagerDiscoveryEvent, any Error>) {
        self.options = options
        self.discover = discover
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
        // Registration, replay and every emitted event share `emission`, so each
        // controller is announced exactly once and in order.
        emission.withLock { _ in
            let connected = state.withLock { s -> [Controller] in
                s.continuations[id] = cont
                return s.byKey.values.filter(\.isConnected)
            }
            for c in connected { cont.yield(.connected(c)) }
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
                    switch e {
                    case .connected(let c), .reconnected(let c): return c
                    default: continue
                    }
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
            s.generation &+= 1
            let generation = s.generation
            let cleanup = s.cleanup
            s.task = Task { [weak self] in
                await cleanup?.value
                guard !Task.isCancelled else { return }
                await self?.run(generation: generation)
            }
        }
    }

    /// Closes every controller (restoring neutral output) and stops discovery.
    /// Waits for the discovery task to end, so no controller opened concurrently
    /// is left behind. Event streams end; a later `events()` starts a fresh
    /// session in which controllers are announced again as new objects.
    public func shutdown() async {
        let (continuations, cleanup) = state.withLock { s in
            s.generation &+= 1
            let all = Array(s.byKey.values)
            let standby = Array(s.standby.values)
            let task = s.task
            let previousCleanup = s.cleanup
            let continuations = Array(s.continuations.values)
            s.byKey.removeAll()
            s.keyByDeviceID.removeAll()
            s.standby.removeAll()
            s.task = nil
            s.continuations.removeAll()
            let cleanup = Task {
                task?.cancel()
                await task?.value
                await previousCleanup?.value
                for c in all { await c.close() }
                for sb in standby { await sb.connection.close() }
            }
            s.cleanup = cleanup
            return (continuations, cleanup)
        }
        // finish invokes onTermination synchronously, which re-enters state.
        for c in continuations { c.finish() }
        await cleanup.value
    }

    private func emit(_ e: ControllerEvent, generation: UInt64) {
        emission.withLock { _ in
            let targets = state.withLock { s in s.generation == generation ? Array(s.continuations.values) : [] }
            for c in targets { c.yield(e) }
        }
    }

    private func run(generation: UInt64) async {
        defer {
            state.withLock { s in
                if s.generation == generation { s.task = nil }
            }
        }
        do {
            for try await event in discover() {
                guard !Task.isCancelled, state.withLock({ $0.generation == generation }) else { break }
                switch event {
                case .connected(let info, let open):
                    guard options.allowedTransports.contains(info.transport) else { continue }
                    await handleConnect(info, open: open, generation: generation)
                case .disconnected(let deviceID):
                    await handleDisconnect(deviceID, generation: generation)
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

    private func handleConnect(_ info: DeviceInfo, open: @Sendable () async throws(TransportError) -> DeviceConnection, generation: UInt64) async {
        let conn: DeviceConnection
        do {
            conn = try await open()
        } catch {
            emit(.failed(info, error), generation: generation)
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
            emit(.reconnected(c), generation: generation)
        }
    }

    private enum DisconnectOutcome {
        case ignore
        case dropStandby(DeviceConnection)
        case lost(Controller, Standby?)
    }

    private func handleDisconnect(_ deviceID: UInt64, generation: UInt64) async {
        let outcome = state.withLock { s -> DisconnectOutcome in
            guard s.generation == generation else { return .ignore }
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
                emit(.reconnected(c), generation: generation)
            } else {
                await standby?.connection.close()
                emit(.disconnected(c), generation: generation)
            }
        }
    }
}

/// Factories defer all connection side effects until after the transport filter.
enum ManagerDiscoveryEvent: Sendable {
    case connected(DeviceInfo, @Sendable () async throws(TransportError) -> DeviceConnection)
    case disconnected(UInt64)
}
