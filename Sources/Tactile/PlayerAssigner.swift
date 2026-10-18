// Local multiplayer / split screen: assigns connected controllers to player
// numbers, keeps them stable across reconnects, and (optionally) shows each
// player's number on the player LEDs and colour on the lightbar.

import Foundation
import Synchronization
public import TactileCore

public struct PlayerOptions: Sendable {
    /// Number of player slots, 1–8.
    public var capacity = 4
    /// Hold a disconnected controller's slot so it returns as the same player.
    public var holdDisconnected = true
    /// Light the player LEDs (1–5 pattern) and lightbar in the player's colour
    /// whenever a controller gains or changes its player number.
    public var applyLights = true
    /// Lightbar colour per player (index 0 = player 1). Missing entries fall
    /// back to `LightbarColor.player(_:)`.
    public var colors: [LightbarColor] = []

    public init() {}

    public func color(for player: Int) -> LightbarColor {
        player >= 1 && player <= colors.count ? colors[player - 1] : .player(player)
    }
}

/// A change in player assignment, with the controller it concerns when known.
public struct PlayerEvent: Sendable {
    public var change: PlayerSlots.Change
    public var controller: Controller?
}

/// Thread-safe player assignment. Feed it controller lifecycle events — either
/// call `attach(to:)` once, or pass each `ControllerEvent` you already consume
/// to `handle(_:)` — and ask it who is player N.
public final class PlayerAssigner: Sendable {
    private struct State {
        var options: PlayerOptions
        var slots: PlayerSlots
        var controllers: [String: Controller] = [:]
        var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
        var attachTask: Task<Void, Never>?
    }
    private let state: Mutex<State>

    public init(options: PlayerOptions = .init()) {
        state = Mutex(State(options: options, slots: PlayerSlots(capacity: options.capacity, holdDisconnected: options.holdDisconnected)))
    }

    deinit {
        state.withLock { s in
            s.attachTask?.cancel()
            for c in s.continuations.values { c.finish() }
        }
    }

    public var options: PlayerOptions { state.withLock { $0.options } }
    public var slots: PlayerSlots { state.withLock { $0.slots } }

    /// Consumes `manager`'s events until the manager shuts down or `detach()`.
    public func attach(to manager: ControllerManager) {
        let events = manager.events()
        let task = Task { [weak self] in
            for await e in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(e)
            }
        }
        state.withLock { s in
            s.attachTask?.cancel()
            s.attachTask = task
        }
    }

    public func detach() {
        state.withLock { $0.attachTask?.cancel(); $0.attachTask = nil }
    }

    /// Player-assignment events. Each call returns an independent stream.
    public func events() -> AsyncStream<PlayerEvent> {
        let (stream, cont) = AsyncStream<PlayerEvent>.makeStream()
        let id = UUID()
        state.withLock { $0.continuations[id] = cont }
        cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }

    /// Updates assignment for one lifecycle event and returns what changed.
    @discardableResult
    public func handle(_ event: ControllerEvent) -> [PlayerSlots.Change] {
        switch event {
        case .connected(let c), .reconnected(let c):
            return mutate(c) { $0.connect(c.id) }
        case .disconnected(let c):
            return mutate(c) { $0.disconnect(c.id) }
        case .failed:
            return []
        }
    }

    /// The controller in `player`'s slot (connected or held), if any.
    public func controller(forPlayer player: Int) -> Controller? {
        state.withLock { s in s.slots.id(of: player).flatMap { s.controllers[$0] } }
    }

    /// `controller`'s player number, if it has one.
    public func player(of controller: Controller) -> Int? {
        state.withLock { $0.slots.player(of: controller.id) }
    }

    /// Connected controllers in player order.
    public var activePlayers: [(player: Int, controller: Controller)] {
        state.withLock { s in s.slots.activePlayers.compactMap { p in s.controllers[p.id].map { (p.player, $0) } } }
    }

    /// Moves `controller` to `player`, swapping with whoever is there.
    @discardableResult
    public func assign(_ controller: Controller, to player: Int) -> [PlayerSlots.Change] {
        mutate(controller) { $0.assign(controller.id, to: player, connected: controller.isConnected) }
    }

    @discardableResult
    public func release(player: Int) -> [PlayerSlots.Change] {
        mutate(nil) { $0.release(player: player) }
    }

    /// Changes options. Capacity changes release slots beyond the new size;
    /// turning lights on re-applies them to every connected player.
    public func update(_ body: (inout PlayerOptions) -> Void) {
        let (changes, relight) = state.withLock { s -> ([PlayerSlots.Change], Bool) in
            let wasLit = s.options.applyLights
            body(&s.options)
            s.options.capacity = min(max(s.options.capacity, 1), PlayerSlots.maxCapacity)
            s.slots.holdDisconnected = s.options.holdDisconnected
            let changes = s.slots.resize(s.options.capacity)
            return (changes, !wasLit && s.options.applyLights)
        }
        publish(changes, known: state.withLock { $0.controllers })
        if relight {
            for (p, c) in activePlayers { light(c, player: p) }
        }
    }

    private func mutate(_ controller: Controller?, _ body: (inout PlayerSlots) -> [PlayerSlots.Change]) -> [PlayerSlots.Change] {
        let (changes, known) = state.withLock { s -> ([PlayerSlots.Change], [String: Controller]) in
            if let controller { s.controllers[controller.id] = controller }
            let known = s.controllers
            let changes = body(&s.slots)
            // Forget controllers that no longer hold any slot (events below
            // still name them, from `known`).
            let held = Set(s.slots.slots.compactMap { $0?.id })
            s.controllers = s.controllers.filter { held.contains($0.key) }
            return (changes, known)
        }
        publish(changes, known: known)
        return changes
    }

    private func publish(_ changes: [PlayerSlots.Change], known: [String: Controller] = [:]) {
        guard !changes.isEmpty else { return }
        let (conts, current, lights) = state.withLock { s in (Array(s.continuations.values), s.controllers, s.options.applyLights) }
        for change in changes {
            let controller = current[change.id] ?? known[change.id]
            for c in conts { c.yield(PlayerEvent(change: change, controller: controller)) }
            guard lights, let controller, controller.isConnected else { continue }
            switch change {
            case .joined(let p, _), .rejoined(let p, _), .moved(_, let p, _): light(controller, player: p)
            default: break
            }
        }
    }

    private func light(_ c: Controller, player: Int) {
        let color = options.color(for: player)
        Task { try? await c.apply(OutputState(lightbar: color, playerLEDs: .player(player))) }
    }
}
