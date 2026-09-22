import CoreHaptics
import Foundation
import GameController

extension Probe {
    /// Exercises GameController's DualSense surface and reports what reads back.
    /// A command-line tool is never "frontmost", so this measures background
    /// behaviour; run the sample app for the frontmost case (see TESTING.md).
    @MainActor
    static func gameController(seconds: Double) async {
        GCController.shouldMonitorBackgroundEvents = true
        log("shouldMonitorBackgroundEvents = \(GCController.shouldMonitorBackgroundEvents)")
        GCController.startWirelessControllerDiscovery {}
        let deadline = Date().addingTimeInterval(4)
        while GCController.controllers().isEmpty && Date() < deadline {
            try? await Task.sleep(for: .seconds(0.1))
        }
        GCController.stopWirelessControllerDiscovery()
        let controllers = GCController.controllers()
        log("GCController.controllers(): \(controllers.count)")
        for c in controllers {
            log("• \(c.vendorName ?? "?") category=\(c.productCategory) attached=\(c.isAttachedToDevice)")
            log("  battery: \(c.battery.map { "\(Int($0.batteryLevel * 100))% state=\($0.batteryState.rawValue)" } ?? "unavailable")")
            log("  light: \(c.light.map { "present color=\($0.color.red),\($0.color.green),\($0.color.blue)" } ?? "unavailable")")
            log("  haptics localities: \(c.haptics.map { $0.supportedLocalities.map(\.rawValue).sorted() } ?? [])")
            log("  motion: \(c.motion.map { "present sensorsActive=\($0.sensorsActive) hasRotationRate=\($0.hasRotationRate)" } ?? "unavailable")")
            log("  physical input elements: \(c.physicalInputProfile.elements.keys.sorted().joined(separator: ", "))")
            guard let ds = c.extendedGamepad as? GCDualSenseGamepad else {
                log("  not a GCDualSenseGamepad")
                continue
            }
            c.light?.color = GCColor(red: 1, green: 0, blue: 1)
            log("  set light → magenta; reads back \(c.light.map { "\($0.color.red),\($0.color.green),\($0.color.blue)" } ?? "-")")
            let r = ds.rightTrigger, l = ds.leftTrigger
            r.setModeFeedbackWithStartPosition(0.2, resistiveStrength: 1.0)
            l.setModeWeaponWithStartPosition(0.2, endPosition: 0.6, resistiveStrength: 1.0)
            try? await Task.sleep(for: .seconds(0.3))
            log("  setMode R=feedback L=weapon → read back R.mode=\(r.mode.rawValue) status=\(r.status.rawValue) arm=\(r.armPosition); L.mode=\(l.mode.rawValue) status=\(l.status.rawValue)")
            // The engine and player must outlive the observation window: a
            // released CHHapticEngine stops, cutting the event off and turning
            // this probe into a false negative.
            var hapticEngine: CHHapticEngine?
            var hapticPlayer: (any CHHapticPatternPlayer)?
            if let engine = c.haptics?.createEngine(withLocality: .default) {
                do {
                    try startEngine(engine)
                    let e = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    ], relativeTime: 0, duration: 0.3)
                    let player = try engine.makePlayer(with: try CHHapticPattern(events: [e], parameters: []))
                    hapticEngine = engine
                    hapticPlayer = player
                    try player.start(atTime: CHHapticTimeImmediate)
                    log("  Core Haptics engine started a 300 ms continuous event")
                } catch {
                    log("  Core Haptics failed: \(error)")
                }
            } else {
                log("  haptics engine unavailable")
            }
            log("  Observe the controller for \(Int(seconds)) s: does the lightbar turn magenta? are triggers stiff?")
            try? await Task.sleep(for: .seconds(seconds))
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            if let hapticEngine { stopEngine(hapticEngine) }
            r.setModeOff(); l.setModeOff()
            try? await Task.sleep(for: .seconds(0.2))
        }
    }
}

// Synchronous wrappers: the async overloads send the non-Sendable engine off
// the main actor, which Swift 6.1 rejects.
private func startEngine(_ engine: CHHapticEngine) throws {
    try engine.start()
}

private func stopEngine(_ engine: CHHapticEngine) {
    engine.stop(completionHandler: nil)
}
