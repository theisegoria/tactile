import AVFAudio
import Foundation
import Tactile

enum Commands {
    /// Longest accepted duration for `--hold`, rumble and bench seconds (one day).
    /// `Duration.seconds(_:)` traps on non-finite or out-of-range values, and a
    /// trap skips the neutral restore, so durations are validated up front.
    static let maxSeconds: Double = 86_400

    /// Parses a duration argument strictly: finite, 0…`maxSeconds`.
    static func parseSeconds(_ text: String, _ what: String) throws -> Double {
        guard let v = Double(text), v.isFinite, v >= 0, v <= maxSeconds else {
            throw CLIError("\(what) must be a number of seconds between 0 and \(Int(maxSeconds)), got '\(text)'")
        }
        return v
    }

    static func hold(_ seconds: Double) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        let s = min(seconds, maxSeconds)
        print("holding \(s) s (Ctrl-C to stop)…")
        try await Task.sleep(for: .seconds(s))
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
            let analogMoved = last.map { moved($0, s) } ?? true
            guard changed || (periodic && (showIMU || showTouch || analogMoved)) else { continue }
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

    /// True when a stick axis or trigger moved by more than a small noise band.
    static func moved(_ a: InputState, _ b: InputState) -> Bool {
        func d(_ x: UInt8, _ y: UInt8) -> Bool { abs(Int(x) - Int(y)) > 3 }
        return d(a.leftStick.x, b.leftStick.x) || d(a.leftStick.y, b.leftStick.y)
            || d(a.rightStick.x, b.rightStick.x) || d(a.rightStick.y, b.rightStick.y)
            || d(a.l2, b.l2) || d(a.r2, b.r2)
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
        if let v = try optionValue(a, "--mute") {
            guard let m = ["off": MuteLED.off, "on": .on, "pulse": .pulse][v] else {
                throw CLIError("bad --mute value '\(v)' (off|on|pulse)")
            }
            state.muteLED = m
        }
        if let v = try optionValue(a, "--brightness") {
            guard let b = ["high": LEDBrightness.high, "medium": .medium, "low": .low][v] else {
                throw CLIError("bad --brightness value '\(v)' (high|medium|low)")
            }
            state.playerLEDBrightness = b
        }
        try await c.apply(state)
        print("player LEDs → 0x\(String(leds.rawValue, radix: 16))\(state.muteLED.map { ", mute LED \($0)" } ?? "")")
    }

    static func trigger(_ c: Controller, _ a: [String]) async throws {
        guard a.count >= 2 else { throw CLIError("usage: trigger <left|right|both> <effect> [params]") }
        let sides: [TriggerSide]
        switch a[0] {
        case "left": sides = [.left]
        case "right": sides = [.right]
        case "both": sides = [.left, .right]
        default: throw CLIError("bad side '\(a[0])' (left|right|both)")
        }
        let effect = try parseEffect(a[1], Array(a.dropFirst(2)))
        var state = OutputState()
        for s in sides {
            if s == .left { state.leftTrigger = effect } else { state.rightTrigger = effect }
        }
        try await c.apply(state)
        print("\(a[0]) trigger → \(a[1]) [\(effect.bytes.hexString)]\(effect.mode?.isOfficial == false ? " (unofficial effect)" : "")")
    }

    static func parseEffect(_ name: String, _ p: [String]) throws -> TriggerEffect {
        // Strict: every parameter must be an integer and the count must match,
        // so a typo is an error instead of shifting values into other slots.
        func ints(_ k: Int) throws -> [Int] {
            let n = try p.map { t in
                guard let v = Int(t) else { throw CLIError("effect '\(name)': '\(t)' is not an integer") }
                return v
            }
            guard n.count == k else { throw CLIError("effect '\(name)' needs exactly \(k) integer parameters, got \(n.count)") }
            return n
        }
        var n: [Int] = []
        func need(_ k: Int) throws { n = try ints(k) }
        switch name {
        case "off": try need(0); return .off
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

    /// The value following `flag`, or nil when the flag is absent. A flag given
    /// without a value is an error rather than being silently ignored.
    static func optionValue(_ a: [String], _ flag: String) throws -> String? {
        guard let i = a.firstIndex(of: flag) else { return nil }
        guard i + 1 < a.count else { throw CLIError("\(flag) needs a value") }
        return a[i + 1]
    }

    /// Validated `haptic --effect` arguments. Parsed before haptics start, so a
    /// bad value never leaves the pump running (and rumble suppressed) on exit.
    struct EffectArgs {
        var name: String
        var effect: HapticEffect
        var side: HapticSide
        var repeats: Int
    }

    static func parseEffectArgs(_ a: [String]) throws -> EffectArgs? {
        guard let name = try optionValue(a, "--effect") else { return nil }
        let effect: HapticEffect
        switch name {
        case "click": effect = .click()
        case "detent": effect = .detent()
        case "texture": effect = .texture()
        case "impact": effect = .impact()
        default: throw CLIError("unknown haptic effect '\(name)' (click|detent|texture|impact)")
        }
        var side = HapticSide.both
        if let v = try optionValue(a, "--side") {
            guard let s = HapticSide(rawValue: v) else { throw CLIError("bad --side '\(v)' (left|right|both)") }
            side = s
        }
        var repeats = 5
        if let v = try optionValue(a, "--repeat") {
            guard let r = Int(v), (0...1000).contains(r) else { throw CLIError("--repeat must be an integer 0…1000, got '\(v)'") }
            repeats = r
        }
        return EffectArgs(name: name, effect: effect, side: side, repeats: repeats)
    }

    static func haptic(_ c: Controller, _ a: [String]) async throws {
        var gain: Float = 1
        if let v = try optionValue(a, "--gain") {
            guard let g = Float(v), g.isFinite, g >= 0 else { throw CLIError("--gain must be a finite number >= 0, got '\(v)'") }
            gain = g
        }
        let effectArgs = try parseEffectArgs(a)
        // Positional file path: skip flags and the values that follow them.
        let valueFlags: Set = ["--gain", "--effect", "--side", "--repeat"]
        var path: String?
        var i = 0
        while i < a.count {
            if valueFlags.contains(a[i]) { i += 2; continue }
            if !a[i].hasPrefix("--"), path == nil { path = a[i] }
            i += 1
        }
        guard effectArgs != nil || a.contains("--mic") || path != nil else {
            throw CLIError("usage: haptic <file.wav> | --mic | --effect NAME")
        }
        try await c.startHaptics()
        defer { printMetrics(c) }
        if let e = effectArgs {
            for k in 0..<e.repeats {
                try await c.play(e.effect, side: e.side)
                print("played \(e.name) \(k + 1)/\(e.repeats)")
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
        } else if let path {
            let url = URL(fileURLWithPath: path)
            print("streaming \(url.lastPathComponent) → haptics…")
            let start = Date()
            try await AudioFileSource.play(url: url, mixer: c.haptics, gain: gain)
            print(String(format: "done in %.2f s", Date().timeIntervalSince(start)))
        }
        await c.stopHaptics()
    }

    static func printMetrics(_ c: Controller) {
        if let m = c.hapticsMetrics() { print(m) }
    }
}
