// Pairs HID connections with GCController objects.
//
// Identity on the HID side is the controller's Bluetooth MAC (feature report
// 0x09, cross-checked with the HID serial number). GameController exposes no
// public MAC or HID identifier, so on the GameController side the bridge
// matches by (1) uniqueness — one unmatched DualSense on each side — and
// otherwise (2) input correlation: digital button transitions that leave the
// same set of standard buttons pressed on both sides within a short window,
// paired one-to-one. Analog motion (sticks, touchpad, trigger pressure) is
// never counted. It never matches by connection order.
//
// The GameController side is sampled from `hidInput` (HID input arrives
// continuously, every few milliseconds); the bridge never installs
// GameController handlers, so the app's `valueChangedHandler`s and
// `handlerQueue` are left alone.

public import GameController
public import TactileCore
import Foundation

@MainActor
public final class ControllerBridge {
    public enum MatchReason: String, Sendable {
        case unique
        case inputCorrelation
    }

    public struct Match: Sendable {
        public var address: MACAddress
        public var reason: MatchReason
    }

    public private(set) var matches: [ObjectIdentifier: (controller: GCController, match: Match)] = [:]

    /// A digital transition: when it was seen and which standard buttons were
    /// pressed afterwards.
    struct Edge: Equatable {
        var time: TimeInterval
        var buttons: Buttons
    }

    /// The buttons both APIs report. GameController cannot see Edge paddles,
    /// and the PS / mute / touchpad-click buttons are often system-reserved.
    static let standardButtons: Buttons = [
        .cross, .circle, .square, .triangle, .l1, .r1, .options, .create,
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
    ]

    private var hidDevices: Set<MACAddress> = []
    private var hidEdges: [MACAddress: [Edge]] = [:]
    private var gcEdges: [ObjectIdentifier: [Edge]] = [:]
    private var lastHIDButtons: [MACAddress: Buttons] = [:]
    /// DualSense GameController objects seen via connect notifications.
    private var attached: [ObjectIdentifier: GCController] = [:]
    private var lastGCButtons: [ObjectIdentifier: Buttons] = [:]
    private var observers: [any NSObjectProtocol] = []
    /// Called whenever a match is made or removed.
    public var onChange: (@MainActor (GCController, MACAddress?) -> Void)?

    /// Edges within this window count as the same physical event.
    public var correlationWindow: TimeInterval = 0.035
    /// Coincident edges required before an input-correlation match is accepted.
    public var requiredCoincidences = 3

    public init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            // Delivered on the main queue, so hopping onto the main actor is safe.
            nonisolated(unsafe) let c = n.object as? GCController
            MainActor.assumeIsolated {
                if let c { self?.attach(c) }
            }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            // Delivered on the main queue, so hopping onto the main actor is safe.
            nonisolated(unsafe) let c = n.object as? GCController
            MainActor.assumeIsolated {
                if let c { self?.detach(c) }
            }
        })
        for c in GCController.controllers() { attach(c) }
    }

    /// True for GameController objects backed by a DualSense or DualSense Edge.
    public static func isDualSense(_ c: GCController) -> Bool {
        c.extendedGamepad is GCDualSenseGamepad
            || c.productCategory == GCProductCategoryDualSense
            || c.productCategory.localizedCaseInsensitiveContains("DualSense")
    }

    /// Returns the GCController matched to a HID device, if any.
    public func controller(for address: MACAddress) -> GCController? {
        matches.values.first { $0.match.address == address }?.controller
    }

    /// Returns the HID address matched to a GCController, if any. Apps use this
    /// to find the extended interface for a controller they got from GameController.
    public func address(for controller: GCController) -> MACAddress? {
        matches[ObjectIdentifier(controller)]?.match.address
    }

    // MARK: HID side

    public func hidDeviceConnected(_ address: MACAddress) {
        hidDevices.insert(address)
        tryUniqueMatch()
    }

    public func hidDeviceDisconnected(_ address: MACAddress) {
        hidDevices.remove(address)
        hidEdges[address] = nil
        lastHIDButtons[address] = nil
        for (k, v) in matches where v.match.address == address {
            matches[k] = nil
            onChange?(v.controller, nil)
        }
    }

    /// Feed every decoded HID input so the bridge can correlate button edges.
    /// Each call also samples the GameController state of unmatched
    /// controllers, at the same `time`.
    public func hidInput(_ address: MACAddress, buttons: Buttons, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var changed = sampleGameControllers(at: time)
        let now = buttons.intersection(Self.standardButtons)
        let previous = lastHIDButtons[address]
        lastHIDButtons[address] = now
        if let previous, previous != now, isUnmatched(address) {
            hidEdges[address, default: []].append(Edge(time: time, buttons: now))
            trim(&hidEdges[address, default: []], now: time)
            changed = true
        }
        if changed { tryCorrelationMatch(now: time) }
    }

    // MARK: GameController side

    private func attach(_ c: GCController) {
        guard Self.isDualSense(c) else { return }
        attached[ObjectIdentifier(c)] = c
        tryUniqueMatch()
    }

    private func detach(_ c: GCController) {
        let id = ObjectIdentifier(c)
        attached[id] = nil
        gcEdges[id] = nil
        lastGCButtons[id] = nil
        if matches.removeValue(forKey: id) != nil { onChange?(c, nil) }
    }

    /// The standard buttons a GameController gamepad reports as pressed.
    static func standardButtons(of g: GCExtendedGamepad) -> Buttons {
        var b: Buttons = []
        if g.buttonA.isPressed { b.insert(.cross) }
        if g.buttonB.isPressed { b.insert(.circle) }
        if g.buttonX.isPressed { b.insert(.square) }
        if g.buttonY.isPressed { b.insert(.triangle) }
        if g.leftShoulder.isPressed { b.insert(.l1) }
        if g.rightShoulder.isPressed { b.insert(.r1) }
        if g.buttonMenu.isPressed { b.insert(.options) }
        if g.buttonOptions?.isPressed == true { b.insert(.create) }
        if g.dpad.up.isPressed { b.insert(.dpadUp) }
        if g.dpad.down.isPressed { b.insert(.dpadDown) }
        if g.dpad.left.isPressed { b.insert(.dpadLeft) }
        if g.dpad.right.isPressed { b.insert(.dpadRight) }
        return b
    }

    /// Records a GameController edge for every unmatched controller whose
    /// standard-button state changed since the last sample. Returns true if
    /// any edge was recorded.
    private func sampleGameControllers(at time: TimeInterval) -> Bool {
        var recorded = false
        for (id, c) in attached where matches[id] == nil {
            guard let g = c.extendedGamepad else { continue }
            let now = Self.standardButtons(of: g)
            let previous = lastGCButtons[id]
            lastGCButtons[id] = now
            // The first sample is a baseline, not a transition.
            guard let previous, previous != now else { continue }
            gcEdges[id, default: []].append(Edge(time: time, buttons: now))
            trim(&gcEdges[id, default: []], now: time)
            recorded = true
        }
        return recorded
    }

    // MARK: Matching

    private func isUnmatched(_ a: MACAddress) -> Bool { !matches.values.contains { $0.match.address == a } }

    private var unmatchedGC: [GCController] {
        attached.filter { matches[$0.key] == nil }.map(\.value)
    }

    private func tryUniqueMatch() {
        let hid = hidDevices.filter(isUnmatched)
        let gc = unmatchedGC
        // Only when the whole system has exactly one of each, so we cannot be wrong.
        let totalGC = GCController.controllers().filter(Self.isDualSense).count
        guard hid.count == 1, gc.count == 1, totalGC == 1, hidDevices.count == 1, let a = hid.first, let c = gc.first else { return }
        record(c, Match(address: a, reason: .unique))
    }

    private func tryCorrelationMatch(now: TimeInterval) {
        for c in unmatchedGC {
            let ge = gcEdges[ObjectIdentifier(c)] ?? []
            guard ge.count >= requiredCoincidences else { continue }
            var scores: [(MACAddress, Int)] = []
            for a in hidDevices where isUnmatched(a) {
                scores.append((a, Self.pairedEdges(ge, hidEdges[a] ?? [], window: correlationWindow)))
            }
            scores.sort { $0.1 > $1.1 }
            guard let best = scores.first, best.1 >= requiredCoincidences else { continue }
            // Require a clear winner.
            if scores.count > 1, scores[1].1 * 2 > best.1 { continue }
            record(c, Match(address: best.0, reason: .inputCorrelation))
        }
    }

    /// Number of GameController edges that can be paired one-to-one with HID
    /// edges leaving the same buttons pressed within `window`. Each HID edge
    /// pairs at most once (with the closest candidate), so a burst on one side
    /// cannot score several times against a single edge on the other.
    nonisolated static func pairedEdges(_ gc: [Edge], _ hid: [Edge], window: TimeInterval) -> Int {
        var used = [Bool](repeating: false, count: hid.count)
        var pairs = 0
        for g in gc {
            var best: (index: Int, distance: TimeInterval)?
            for (i, h) in hid.enumerated() where !used[i] && h.buttons == g.buttons {
                let d = abs(h.time - g.time)
                if d <= window, d < (best?.distance ?? .infinity) { best = (i, d) }
            }
            if let best {
                used[best.index] = true
                pairs += 1
            }
        }
        return pairs
    }

    private func record(_ c: GCController, _ m: Match) {
        matches[ObjectIdentifier(c)] = (c, m)
        gcEdges[ObjectIdentifier(c)] = nil
        hidEdges[m.address] = nil
        onChange?(c, m.address)
    }

    private func trim(_ edges: inout [Edge], now: TimeInterval) {
        edges.removeAll { now - $0.time > 10 }
        if edges.count > 64 { edges.removeFirst(edges.count - 64) }
    }
}
