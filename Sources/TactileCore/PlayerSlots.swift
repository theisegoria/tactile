// Player-slot assignment for local multiplayer / split screen. Pure logic:
// which controller is player 1, 2, 3…, kept stable across disconnects and
// reconnects. Controllers are identified by a stable string (the Bluetooth
// address in practice), never by connection order alone.

public struct PlayerSlots: Sendable, Hashable, Codable {
    public struct Slot: Sendable, Hashable, Codable {
        public var id: String
        public var connected: Bool
    }

    /// What changed. Player numbers are 1-based.
    public enum Change: Sendable, Hashable, Codable {
        /// A controller took a free slot.
        case joined(player: Int, id: String)
        /// A controller came back to the slot held for it.
        case rejoined(player: Int, id: String)
        /// A controller disconnected; its slot is held for it.
        case left(player: Int, id: String)
        /// A slot was emptied.
        case released(player: Int, id: String)
        /// A controller moved between slots (assignment or swap).
        case moved(from: Int, to: Int, id: String)
        /// Every slot is taken by a connected controller.
        case rejected(id: String)

        public var id: String {
            switch self {
            case .joined(_, let id), .rejoined(_, let id), .left(_, let id), .released(_, let id), .rejected(let id): id
            case .moved(_, _, let id): id
            }
        }

        /// The player number the controller holds after this change, if any.
        public var player: Int? {
            switch self {
            case .joined(let p, _), .rejoined(let p, _), .left(let p, _): p
            case .moved(_, let to, _): to
            case .released, .rejected: nil
            }
        }
    }

    public static let maxCapacity = 8

    public private(set) var slots: [Slot?]
    /// Keep a disconnected controller's slot so it returns as the same player.
    public var holdDisconnected: Bool

    public init(capacity: Int = 4, holdDisconnected: Bool = true) {
        slots = Array(repeating: nil, count: min(max(capacity, 1), Self.maxCapacity))
        self.holdDisconnected = holdDisconnected
    }

    public var capacity: Int { slots.count }

    public func player(of id: String) -> Int? {
        slots.firstIndex { $0?.id == id }.map { $0 + 1 }
    }

    public func slot(_ player: Int) -> Slot? {
        (1...capacity).contains(player) ? slots[player - 1] : nil
    }

    public func id(of player: Int) -> String? { slot(player)?.id }

    /// Connected controllers in player order.
    public var activePlayers: [(player: Int, id: String)] {
        slots.enumerated().compactMap { i, s in s.flatMap { $0.connected ? (i + 1, $0.id) : nil } }
    }

    /// A controller connected (or reconnected).
    public mutating func connect(_ id: String) -> [Change] {
        if let p = player(of: id) {
            guard slots[p - 1]?.connected == false else { return [] }
            slots[p - 1]?.connected = true
            return [.rejoined(player: p, id: id)]
        }
        if let free = slots.firstIndex(where: { $0 == nil }) {
            slots[free] = Slot(id: id, connected: true)
            return [.joined(player: free + 1, id: id)]
        }
        // Full: reclaim the lowest slot held for a disconnected controller.
        if let held = slots.firstIndex(where: { $0?.connected == false }), let old = slots[held] {
            slots[held] = Slot(id: id, connected: true)
            return [.released(player: held + 1, id: old.id), .joined(player: held + 1, id: id)]
        }
        return [.rejected(id: id)]
    }

    /// A controller disconnected.
    public mutating func disconnect(_ id: String) -> [Change] {
        guard let p = player(of: id), slots[p - 1]?.connected == true else { return [] }
        if holdDisconnected {
            slots[p - 1]?.connected = false
            return [.left(player: p, id: id)]
        }
        slots[p - 1] = nil
        return [.released(player: p, id: id)]
    }

    /// Puts `id` in `player`'s slot. An occupant swaps into `id`'s old slot, or
    /// moves to the first free slot when `id` had none (or is released if
    /// there is no room).
    public mutating func assign(_ id: String, to player: Int, connected: Bool = true) -> [Change] {
        guard (1...capacity).contains(player) else { return [] }
        let target = player - 1
        let from = self.player(of: id)
        if from == player { return [] }
        var changes: [Change] = []
        let occupant = slots[target]
        let mine = from.flatMap { slots[$0 - 1] } ?? Slot(id: id, connected: connected)
        if let from {
            slots[from - 1] = occupant
            if let occupant { changes.append(.moved(from: player, to: from, id: occupant.id)) }
            slots[target] = mine
            changes.append(.moved(from: from, to: player, id: id))
        } else {
            slots[target] = mine
            changes.append(.joined(player: player, id: id))
            if let occupant {
                if let free = slots.firstIndex(where: { $0 == nil }) {
                    slots[free] = occupant
                    changes.append(.moved(from: player, to: free + 1, id: occupant.id))
                } else {
                    changes.append(.released(player: player, id: occupant.id))
                }
            }
        }
        return changes
    }

    /// Empties a slot (for example, a player leaving the session).
    public mutating func release(player: Int) -> [Change] {
        guard let s = slot(player) else { return [] }
        slots[player - 1] = nil
        return [.released(player: player, id: s.id)]
    }

    /// Changes capacity. Slots beyond the new capacity are released.
    public mutating func resize(_ capacity: Int) -> [Change] {
        let n = min(max(capacity, 1), Self.maxCapacity)
        var changes: [Change] = []
        if n < slots.count {
            for i in n..<slots.count { if let s = slots[i] { changes.append(.released(player: i + 1, id: s.id)) } }
            slots.removeLast(slots.count - n)
        } else {
            slots += Array(repeating: nil, count: n - slots.count)
        }
        return changes
    }
}

extension LightbarColor {
    /// Conventional player colours: blue, red, green, pink, then repeats
    /// dimmer for players 5–8.
    public static func player(_ n: Int) -> LightbarColor {
        let base: [LightbarColor] = [
            LightbarColor(red: 0, green: 64, blue: 255),
            LightbarColor(red: 255, green: 32, blue: 32),
            LightbarColor(red: 32, green: 224, blue: 64),
            LightbarColor(red: 240, green: 48, blue: 200),
        ]
        guard n >= 1 else { return .defaultBlue }
        let c = base[(n - 1) % base.count]
        if n <= base.count { return c }
        return LightbarColor(red: c.red / 3, green: c.green / 3, blue: c.blue / 3)
    }
}
