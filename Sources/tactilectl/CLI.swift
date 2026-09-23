// tactilectl — demo and hardware test harness for Tactile.

import AVFAudio
import Foundation
import Tactile

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

@main
struct CLI {
    static let usage = """
    tactilectl \(TactileVersion.string) — DualSense / DualSense Edge over Bluetooth

    usage: tactilectl [--exclusive] [--hold SECONDS] <command> [args]

    commands:
      list                              list connected controllers
      info                              firmware, battery, transport, calibration, conflicts
      monitor [--imu] [--touch] [--raw] stream input (Ctrl-C to stop)
      light <#RRGGBB>                   set the lightbar
      leds <1-5|0xMASK> [--mute off|on|pulse] [--brightness high|medium|low]
      trigger <left|right|both> <effect> [params…]
          effects: off | feedback POS STR | weapon START END STR | vibration POS AMP FREQ
                   slope START END STR_A STR_B | bow START END STR SNAP
                   galloping START END FOOT1 FOOT2 FREQ | machine START END AMP_A AMP_B FREQ PERIOD
                   raw HEX(11 bytes)
      rumble <left 0-255> <right 0-255> [seconds]
      haptic <file.wav> [--gain G]      stream an audio file to the voice coils
      haptic --mic [--gain G]           audio-reactive haptics from the microphone
      haptic --effect <click|detent|texture|impact> [--side left|right|both] [--repeat N]
      conflicts                         list other processes holding the controller
      haptic-bench [seconds]            measure pump cadence/CPU with a null sink (no controller needed)
      permission                        show / request Input Monitoring

    experimental (gate 6, unverified protocol facts):
      descriptor                        parsed report descriptor (all report IDs and sizes)
      audio [--headphone N] [--speaker N] [--mic N] [--path headphones|headphone-left|headphone-left-speaker|speaker]
      speaker <file> [--gain G] [--bitrate BPS] [--report-length N]   Opus → report 0x36
      mic-scan [seconds]                look for the microphone uplink in raw input
      mic-record <out.wav> [seconds] [--report 0xID --toc N [--length N]]
      features [--label L] [--save f.json]   read every declared feature report (read-only)
      features-diff <a.json> <b.json>   compare two snapshots (e.g. two Edge profiles)

    Output is returned to neutral (triggers off, rumble off, lightbar restored)
    on exit, including Ctrl-C. --hold keeps the effect for N seconds first
    (default 3 for output commands).
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var options = ConnectionOptions()
        var hold: Double?
        if let i = args.firstIndex(of: "--exclusive") {
            options.mode = .exclusive
            args.remove(at: i)
        }
        do {
            if let i = args.firstIndex(of: "--hold") {
                guard i + 1 < args.count else { throw CLIError("--hold needs a value") }
                hold = try Commands.parseSeconds(args[i + 1], "--hold")
                args.removeSubrange(i...(i + 1))
            }
            guard let cmd = args.first else {
                print(usage)
                return
            }
            let rest = Array(args.dropFirst())
            switch cmd {
            case "help", "-h", "--help": print(usage)
            case "permission": permission()
            case "list": try await list()
            case "features-diff": try ExperimentalCommands.featuresDiff(rest)
            case "haptic-bench": try await HapticBench.run(seconds: try rest.first.map { try Commands.parseSeconds($0, "haptic-bench seconds") } ?? 5)
            default:
                let holdSeconds = hold
                try await withController(options: options) { c in
                    try await run(cmd, rest, c, hold: holdSeconds)
                }
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func permission() {
        let s = InputMonitoringPermission.status
        print("Input Monitoring: \(s.rawValue)")
        if s != .granted {
            print("Requesting… \(InputMonitoringPermission.request() ? "granted" : "not granted")")
            print("If denied, enable it in System Settings › Privacy & Security › Input Monitoring for your terminal app.")
        }
    }

    static func list() async throws {
        let devices = try await DeviceDiscovery().currentDevices(includeVirtual: true)
        if devices.isEmpty { print("No controllers found.") }
        for (info, _) in devices { print(info) }
        if InputMonitoringPermission.status != .granted {
            print("note: Input Monitoring is \(InputMonitoringPermission.status.rawValue); opening will fail until granted.")
        }
    }

    static func withController(options: ConnectionOptions, _ body: @Sendable (Controller) async throws -> Void) async throws {
        let manager = ControllerManager(options: options)
        var failure: TransportError?
        let failures = Task { () -> TransportError? in
            for await e in manager.events() {
                if case .failed(let info, let err) = e {
                    fputs("could not open \(info): \(err)\n", stderr)
                    return err
                }
            }
            return nil
        }
        guard let controller = await manager.firstController(timeout: .seconds(4)) else {
            failures.cancel()
            failure = await failures.value
            if InputMonitoringPermission.status != .granted {
                throw CLIError("Input Monitoring permission is \(InputMonitoringPermission.status.rawValue). Run `tactilectl permission`.")
            }
            throw CLIError(failure.map { "\($0)" } ?? "No DualSense found. Pair it in System Settings › Bluetooth.")
        }
        failures.cancel()
        SignalTrap.install {
            Task {
                await manager.shutdown()
                exit(130)
            }
        }
        defer { SignalTrap.remove() }
        do {
            try await body(controller)
        } catch {
            await manager.shutdown()
            throw error
        }
        await manager.shutdown()
    }

    static func run(_ cmd: String, _ a: [String], _ c: Controller, hold: Double?) async throws {
        switch cmd {
        case "info": try await Commands.info(c)
        case "monitor": try await Commands.monitor(c, a)
        case "light":
            guard let hex = a.first, let color = LightbarColor(hex: hex) else { throw CLIError("usage: light #RRGGBB") }
            try await c.setLightbar(color)
            print("lightbar → \(hex)")
            try await Commands.hold(hold ?? 3)
        case "leds": try await Commands.leds(c, a); try await Commands.hold(hold ?? 3)
        case "trigger": try await Commands.trigger(c, a); try await Commands.hold(hold ?? 5)
        case "rumble":
            guard a.count >= 2, a.count <= 3, let l = UInt8(a[0]), let r = UInt8(a[1]) else { throw CLIError("usage: rumble LEFT RIGHT [seconds]") }
            let seconds = try a.count > 2 ? Commands.parseSeconds(a[2], "rumble seconds") : (hold ?? 1)
            try await c.setRumble(Rumble(left: l, right: r))
            print("rumble L=\(l) R=\(r)")
            try await Commands.hold(seconds)
        case "haptic": try await Commands.haptic(c, a)
        case "conflicts": Commands.conflicts(c)
        case "descriptor": ExperimentalCommands.descriptor(c)
        case "audio": try await ExperimentalCommands.audio(c, a); try await Commands.hold(hold ?? 3)
        case "speaker": try await ExperimentalCommands.speaker(c, a)
        case "mic-scan": _ = try await ExperimentalCommands.micScan(c, a)
        case "mic-record": try await ExperimentalCommands.micRecord(c, a)
        case "features": try await ExperimentalCommands.features(c, a)
        default: throw CLIError("unknown command '\(cmd)'\n\n\(usage)")
        }
    }
}

/// SIGINT/SIGTERM → neutralise and exit.
enum SignalTrap {
    nonisolated(unsafe) static var sources: [any DispatchSourceSignal] = []

    static func install(_ handler: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: handler)
            s.resume()
            sources.append(s)
        }
    }

    static func remove() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }
}
