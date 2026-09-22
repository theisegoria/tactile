import AVFAudio
import Foundation
import Tactile

enum Commands {
    static func hold(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        print("holding \(seconds) s (Ctrl-C to stop)…")
        try await Task.sleep(for: .seconds(seconds))
    }

    static func info(_ c: Controller) async throws {
        let i = c.info
        print("model:       \(i.model.displayName)")
        print("transport:   \(i.transport.rawValue)")
        print("address:     \(await c.address?.description ?? "unknown")")
        print("serial:      \(i.serialNumber ?? "-")")
        if let fw = await c.firmware {
            print("firmware:    0x\(String(fw.firmwareVersion, radix: 16)) (update \(fw.updateVersionString)), hardware 0x\(String(fw.hardwareVersion, radix: 16)), built \(fw.buildDate) \(fw.buildTime)")
        } else {
            print("firmware:    unavailable")
        }
        let features = await c.connection?.features
        print("features:    vibrationV2=\(features?.vibrationV2 ?? false) edgeButtons=\(features?.hasEdgeButtons ?? false)")
        if let cal = await c.calibration {
            print("calibration: \(cal.isFromDevice ? "from device" : "defaults (report 0x05 unavailable or degenerate)")")
        }
        // Wait briefly for a full input report to learn the battery state.
        for _ in 0..<20 {
            if let b = await c.lastInput?.battery {
                print("battery:     \(b.percent)% \(b.charging.rawValue)")
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let ids = await c.connection?.observedReportIDs {
            print("input IDs:   \(ids.map { "0x" + String($0, radix: 16) })")
        }
        conflicts(c)
    }

    static func conflicts(_ c: Controller) {
        guard let r = c.conflicts() else { return }
        print("other HID clients: \(r.otherClients.isEmpty ? "none" : r.otherClients.map(\.description).joined(separator: ", "))")
        if r.virtualTwins > 0 { print("virtual twins (e.g. Steam Input): \(r.virtualTwins)") }
        if r.hasConflicts {
            print("note: in shared mode another writer can override output (last write wins). Use --exclusive to seize.")
        }
    }

    static func monitor(_ c: Controller, _ a: [String]) async throws {
        let showIMU = a.contains("--imu"), showTouch = a.contains("--touch"), raw = a.contains("--raw")
        var last: InputState?
        var lastPrint = Date.distantPast
        for await e in await c.inputEvents() {
            let s = e.state
            if raw {
                print(e.raw.hexString)
                continue
            }
            let changed = last.map { $0.buttons != s.buttons } ?? true
            let periodic = Date().timeIntervalSince(lastPrint) > 0.1
            guard changed || ((showIMU || showTouch) && periodic) || periodic && abs(Int(s.l2) - Int(last?.l2 ?? 0)) > 3 else { continue }
            lastPrint = Date()
            last = s
            var line = String(format: "L(%3d,%3d) R(%3d,%3d) L2 %3d R2 %3d ", s.leftStick.x, s.leftStick.y, s.rightStick.x, s.rightStick.y, s.l2, s.r2)
            line += "[\(names(s.buttons).joined(separator: " "))]"
            if showIMU, let imu = e.imu {
                line += String(format: " gyro(%7.1f %7.1f %7.1f)°/s acc(%5.2f %5.2f %5.2f)g",
                               imu.gyroDegPerSec.x, imu.gyroDegPerSec.y, imu.gyroDegPerSec.z, imu.accelG.x, imu.accelG.y, imu.accelG.z)
            }
            if showTouch {
                for (i, t) in s.touchPoints.enumerated() where t.active { line += " t\(i)#\(t.id)(\(t.x),\(t.y))" }
            }
            if let b = s.battery { line += " \(b.percent)%" }
            print(line)
        }
        print("controller disconnected")
    }

    static func names(_ b: Buttons) -> [String] {
        let all: [(Buttons, String)] = [
            (.cross, "✕"), (.circle, "○"), (.square, "□"), (.triangle, "△"), (.l1, "L1"), (.r1, "R1"),
            (.l2, "L2"), (.r2, "R2"), (.l3, "L3"), (.r3, "R3"), (.create, "Create"), (.options, "Options"),
            (.ps, "PS"), (.touchpad, "Pad"), (.mute, "Mute"), (.dpadUp, "↑"), (.dpadDown, "↓"),
            (.dpadLeft, "←"), (.dpadRight, "→"), (.fnLeft, "Fn1"), (.fnRight, "Fn2"),
            (.paddleLeft, "PaddleL"), (.paddleRight, "PaddleR"),
        ]
        return all.filter { b.contains($0.0) }.map(\.1)
    }

    static func leds(_ c: Controller, _ a: [String]) async throws {
        guard let spec = a.first else { throw CLIError("usage: leds <1-5|0xMASK> [--mute off|on|pulse]") }
        let leds: PlayerLEDs
        if spec.hasPrefix("0x"), let m = UInt8(spec.dropFirst(2), radix: 16) {
            leds = PlayerLEDs(rawValue: m)
        } else if let n = Int(spec) {
            leds = .player(n)
        } else {
            throw CLIError("bad LED spec '\(spec)'")
        }
        var state = OutputState(playerLEDs: leds)
        if let i = a.firstIndex(of: "--mute"), i + 1 < a.count {
            state.muteLED = ["off": .off, "on": .on, "pulse": .pulse][a[i + 1]] ?? .off
        }
        if let i = a.firstIndex(of: "--brightness"), i + 1 < a.count {
            state.playerLEDBrightness = ["high": .high, "medium": .medium, "low": .low][a[i + 1]]
        }
        try await c.apply(state)
        print("player LEDs → 0x\(String(leds.rawValue, radix: 16))\(state.muteLED.map { ", mute LED \($0)" } ?? "")")
    }

    static func trigger(_ c: Controller, _ a: [String]) async throws {
        guard a.count >= 2 else { throw CLIError("usage: trigger <left|right|both> <effect> [params]") }
        let effect = try parseEffect(a[1], Array(a.dropFirst(2)))
        let sides: [TriggerSide] = a[0] == "both" ? [.left, .right] : [a[0] == "left" ? .left : .right]
        var state = OutputState()
        for s in sides {
            if s == .left { state.leftTrigger = effect } else { state.rightTrigger = effect }
        }
        try await c.apply(state)
        print("\(a[0]) trigger → \(a[1]) [\(effect.bytes.hexString)]\(effect.mode?.isOfficial == false ? " (unofficial effect)" : "")")
    }

    static func parseEffect(_ name: String, _ p: [String]) throws -> TriggerEffect {
        let n = p.compactMap(Int.init)
        func need(_ k: Int) throws { if n.count < k { throw CLIError("effect '\(name)' needs \(k) numeric parameters") } }
        switch name {
        case "off": return .off
        case "feedback": try need(2); return try .feedback(position: n[0], strength: n[1])
        case "weapon": try need(3); return try .weapon(start: n[0], end: n[1], strength: n[2])
        case "vibration": try need(3); return try .vibration(position: n[0], amplitude: n[1], frequency: n[2])
        case "slope": try need(4); return try .slopeFeedback(startPosition: n[0], endPosition: n[1], startStrength: n[2], endStrength: n[3])
        case "bow": try need(4); return try .bow(start: n[0], end: n[1], strength: n[2], snapForce: n[3])
        case "galloping": try need(5); return try .galloping(start: n[0], end: n[1], firstFoot: n[2], secondFoot: n[3], frequency: n[4])
        case "machine": try need(6); return try .machine(start: n[0], end: n[1], amplitudeA: n[2], amplitudeB: n[3], frequency: n[4], period: n[5])
        case "raw":
            guard let b = [UInt8](hex: p.joined()) else { throw CLIError("raw needs hex bytes") }
            return TriggerEffect(rawBytes: b)
        default: throw CLIError("unknown effect '\(name)'")
        }
    }

    static func haptic(_ c: Controller, _ a: [String]) async throws {
        var gain: Float = 1
        if let i = a.firstIndex(of: "--gain"), i + 1 < a.count { gain = Float(a[i + 1]) ?? 1 }
        try await c.startHaptics()
        defer { printMetrics(c) }
        if let i = a.firstIndex(of: "--effect"), i + 1 < a.count {
            let side: HapticSide = a.firstIndex(of: "--side").flatMap { $0 + 1 < a.count ? HapticSide(rawValue: a[$0 + 1]) : nil } ?? .both
            let repeats = a.firstIndex(of: "--repeat").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil } ?? 5
            let effect: HapticEffect = switch a[i + 1] {
            case "detent": .detent()
            case "texture": .texture()
            case "impact": .impact()
            default: .click()
            }
            for k in 0..<repeats {
                try await c.play(effect, side: side)
                print("played \(a[i + 1]) \(k + 1)/\(repeats)")
                try await Task.sleep(for: .milliseconds(400))
            }
            try await Task.sleep(for: .milliseconds(300))
        } else if a.contains("--mic") {
            let engine = AVAudioEngine()
            let tap = AudioTapSource(engine: engine, node: engine.inputNode, mixer: c.haptics, gain: gain)
            tap.start()
            try engine.start()
            print("microphone → haptics. Speak or tap the mic. Ctrl-C to stop.")
            while true {
                try await Task.sleep(for: .seconds(2))
                printMetrics(c)
            }
        } else if let path = a.first(where: { !$0.hasPrefix("--") && Float($0) == nil }) {
            let url = URL(fileURLWithPath: path)
            print("streaming \(url.lastPathComponent) → haptics…")
            let start = Date()
            try await AudioFileSource.play(url: url, mixer: c.haptics, gain: gain)
            print(String(format: "done in %.2f s", Date().timeIntervalSince(start)))
        } else {
            throw CLIError("usage: haptic <file.wav> | --mic | --effect NAME")
        }
        await c.stopHaptics()
    }

    static func printMetrics(_ c: Controller) {
        if let m = c.hapticsMetrics() { print(m) }
    }
}
