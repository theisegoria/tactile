// Pairs HID connections with GCController objects.
//
// Identity on the HID side is the controller's Bluetooth MAC (feature report
// 0x09, cross-checked with the HID serial number). GameController exposes no
// public MAC or HID identifier, so on the GameController side the bridge
// matches by (1) uniqueness — one unmatched DualSense on each side — and
// otherwise (2) input correlation: button edges seen by both APIs within a
// short window. It never matches by connection order.

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
    private var hidDevices: Set<MACAddress> = []
    private var hidEdges: [MACAddress: [TimeInterval]] = [:]
    private var gcEdges: [ObjectIdentifier: [TimeInterval]] = [:]
    private var lastHIDButtons: [MACAddress: Buttons] = [:]
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
    public func hidInput(_ address: MACAddress, buttons: Buttons, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let previous = lastHIDButtons[address] ?? []
        lastHIDButtons[address] = buttons
        // Only standard buttons: GameController cannot see Edge paddles.
        let standard: Buttons = [.cross, .circle, .square, .triangle, .l1, .r1, .options, .create, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]
        guard previous.intersection(standard) != buttons.intersection(standard) else { return }
        guard isUnmatched(address) else { return }
        hidEdges[address, default: []].append(time)
        trim(&hidEdges[address, default: []], now: time)
        tryCorrelationMatch(now: time)
    }

    // MARK: GameController side

    private func attach(_ c: GCController) {
        guard Self.isDualSense(c) else { return }
        c.extendedGamepad?.valueChangedHandler = { [weak self, weak c] _, element in
            guard let c, element is GCControllerButtonInput || element is GCControllerDirectionPad else { return }
            MainActor.assumeIsolated { self?.gcEdge(c) }
        }
        tryUniqueMatch()
    }

    private func detach(_ c: GCController) {
        let id = ObjectIdentifier(c)
        gcEdges[id] = nil
        if matches.removeValue(forKey: id) != nil { onChange?(c, nil) }
    }

    private func gcEdge(_ c: GCController) {
        let id = ObjectIdentifier(c)
        guard matches[id] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        gcEdges[id, default: []].append(now)
        trim(&gcEdges[id, default: []], now: now)
        tryCorrelationMatch(now: now)
    }

    // MARK: Matching

    private func isUnmatched(_ a: MACAddress) -> Bool { !matches.values.contains { $0.match.address == a } }

    private var unmatchedGC: [GCController] {
        GCController.controllers().filter { Self.isDualSense($0) && matches[ObjectIdentifier($0)] == nil }
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
                let he = hidEdges[a] ?? []
                let score = ge.filter { g in he.contains { abs($0 - g) <= correlationWindow } }.count
                scores.append((a, score))
            }
            scores.sort { $0.1 > $1.1 }
            guard let best = scores.first, best.1 >= requiredCoincidences else { continue }
            // Require a clear winner.
            if scores.count > 1, scores[1].1 * 2 > best.1 { continue }
            record(c, Match(address: best.0, reason: .inputCorrelation))
        }
    }

    private func record(_ c: GCController, _ m: Match) {
        matches[ObjectIdentifier(c)] = (c, m)
        gcEdges[ObjectIdentifier(c)] = nil
        hidEdges[m.address] = nil
        onChange?(c, m.address)
    }

    private func trim(_ edges: inout [TimeInterval], now: TimeInterval) {
        edges.removeAll { now - $0 > 10 }
        if edges.count > 64 { edges.removeFirst(edges.count - 64) }
    }
}
