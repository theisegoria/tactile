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
public final class ControllerManager: Sendable {
    public let options: ConnectionOptions
    private let discovery = DeviceDiscovery()
    private struct State {
        var byKey: [String: Controller] = [:]
        var keyByDeviceID: [UInt64: String] = [:]
        var task: Task<Void, Never>?
        var continuations: [UUID: AsyncStream<ControllerEvent>.Continuation] = [:]
    }
    private let state = Mutex(State())

    public init(options: ConnectionOptions = .init()) {
        self.options = options
    }

    deinit { state.withLock { $0.task?.cancel() } }

    /// All controllers seen so far, connected or not.
    public var controllers: [Controller] { state.withLock { Array($0.byKey.values) } }

    /// Starts discovery (idempotent) and returns a stream of lifecycle events.
    /// Already-connected controllers are replayed as `.connected`.
    public func events() -> AsyncStream<ControllerEvent> {
        let (stream, cont) = AsyncStream<ControllerEvent>.makeStream()
        let id = UUID()
        let existing = state.withLock { s -> [Controller] in
            s.continuations[id] = cont
            return s.byKey.values.filter(\.isConnected)
        }
        for c in existing { cont.yield(.connected(c)) }
        cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
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
    public func shutdown() async {
        let (all, task) = state.withLock { s in (Array(s.byKey.values), s.task) }
        task?.cancel()
        for c in all { await c.close() }
        state.withLock { s in
            for c in s.continuations.values { c.finish() }
            s.continuations.removeAll()
            s.task = nil
        }
    }

    private func emit(_ e: ControllerEvent) {
        for c in state.withLock({ Array($0.continuations.values) }) { c.yield(e) }
    }

    private func run() async {
        do {
            for try await event in discovery.events() {
                switch event {
                case .connected(let info, let ref):
                    await handleConnect(info, ref)
                case .disconnected(let deviceID):
                    handleDisconnect(deviceID)
                }
            }
        } catch {}
    }

    private func handleConnect(_ info: DeviceInfo, _ ref: HIDDeviceClientReference) async {
        let conn: DeviceConnection
        do {
            conn = try await DeviceConnection.open(ref, info: info, options: options)
        } catch {
            emit(.failed(info, error))
            return
        }
        let key = await conn.address?.description ?? info.serialNumber ?? "id-\(info.deviceID)"
        let (existing, created) = state.withLock { s -> (Controller?, Controller?) in
            s.keyByDeviceID[info.deviceID] = key
            if let c = s.byKey[key] { return (c, nil) }
            let c = Controller(connection: conn, info: info, id: key)
            s.byKey[key] = c
            return (nil, c)
        }
        if let existing {
            await existing.replaceConnection(conn, info: info)
            emit(.reconnected(existing))
        } else if let created {
            emit(.connected(created))
        }
    }

    private func handleDisconnect(_ deviceID: UInt64) {
        let c = state.withLock { s -> Controller? in
            guard let key = s.keyByDeviceID.removeValue(forKey: deviceID) else { return nil }
            return s.byKey[key]
        }
        guard let c else { return }
        c.connectionLost()
        emit(.disconnected(c))
    }
}
