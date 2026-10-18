// Sample host app: shows live input, drives lightbar/LEDs/triggers/haptics,
// and demonstrates the GameController bridge. See Samples/SwiftSample/README.md.

import GameController
import SwiftUI
import Tactile

@main
struct TactileDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Tactile Demo", id: "main") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 520, minHeight: 560)
                .task { await appDelegate.model.run() }
        }
    }
}

/// Owns the model so that quitting can restore neutral output first: the
/// library installs no exit hook, and a plain Cmd-Q would otherwise leave the
/// triggers, lightbar and LEDs in whatever state the demo last set.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DemoModel()
    private var terminating = false
    private var replied = false
    private var cleanup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let model = model
        cleanup = Task {
            await model.shutdown()
            finishTermination(sender)
        }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            cleanup?.cancel()
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ application: NSApplication) {
        guard !replied else { return }
        replied = true
        deadline?.cancel()
        application.reply(toApplicationShouldTerminate: true)
    }
}

@MainActor
@Observable
final class DemoModel {
    var status = "Looking for a DualSense…"
    var input: InputState?
    var imu: CalibratedIMU?
    var controller: Controller?
    var gcName: String?
    var permission = InputMonitoringPermission.status
    var color = Color.blue
    var metrics = ""

    private let manager = ControllerManager()
    private var running = false
    private var generation: UInt64 = 0
    private var inputTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private let bridge = ControllerBridge()
    /// Addresses reported to the bridge, by controller. `Controller.address`
    /// is already nil when `.disconnected` arrives (the connection is gone),
    /// so the address to withdraw from the bridge has to be remembered here.
    private var bridgedAddresses: [Controller.ID: MACAddress] = [:]

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false; inputTask?.cancel() }
        if permission != .granted { InputMonitoringPermission.request() }
        permission = InputMonitoringPermission.status
        bridge.onChange = { [weak self] gc, address in
            self?.gcName = address.map { "\(gc.vendorName ?? "GCController") ↔ \($0)" }
        }
        for await event in manager.events() {
            switch event {
            case .connected(let c), .reconnected(let c):
                guard controller == nil || controller === c else { continue }
                await select(c)
                if let a = await c.address {
                    if let old = bridgedAddresses[c.id], old != a { bridge.hidDeviceDisconnected(old) }
                    bridgedAddresses[c.id] = a
                    bridge.hidDeviceConnected(a)
                }
            case .disconnected(let c):
                if controller === c {
                    await select(nil)
                    status = "\(c.model.displayName) disconnected"
                    if let next = manager.controllers.first(where: { $0.isConnected }) { await select(next) }
                }
                if let a = bridgedAddresses.removeValue(forKey: c.id) { bridge.hidDeviceDisconnected(a) }
            case .failed(_, let error):
                status = "\(error)"
                permission = InputMonitoringPermission.status
            }
        }
    }

    /// Closes every controller, restoring neutral output (triggers off, rumble
    /// off, lightbar and LEDs restored). Called before the app quits.
    func shutdown() async {
        await select(nil)
        for a in bridgedAddresses.values { bridge.hidDeviceDisconnected(a) }
        bridgedAddresses.removeAll()
        await manager.shutdown()
    }

    private func select(_ c: Controller?) async {
        generation &+= 1
        let current = generation
        inputTask?.cancel()
        outputTask?.cancel()
        let previous = controller
        controller = nil
        input = nil; imu = nil; metrics = ""; gcName = nil
        await outputTask?.value
        await previous?.stopHaptics()
        await previous?.neutralize()
        guard generation == current else { return }
        controller = c
        if let c {
            status = "\(c.model.displayName) connected over \(c.transport.rawValue)"
            inputTask = Task { await consume(c, generation: current) }
        }
    }

    private func consume(_ c: Controller, generation: UInt64) async {
        let address = await c.address
        var nextPublish = ContinuousClock.now
        for await e in await c.inputEvents() {
            guard !Task.isCancelled, self.generation == generation, controller === c else { return }
            if let address { bridge.hidInput(address, buttons: e.state.buttons) }
            // UI at ~30 Hz is plenty.
            if ContinuousClock.now >= nextPublish {
                nextPublish = .now + .milliseconds(34)
                input = e.state
                imu = e.imu
                metrics = c.hapticsMetrics()?.description ?? ""
            }
        }
    }

    private func output(_ operation: @escaping @Sendable (Controller) async throws -> Void) {
        guard let c = controller else { return }
        let current = generation
        let previous = outputTask
        previous?.cancel()
        outputTask = Task {
            await previous?.value
            guard !Task.isCancelled, generation == current, controller === c else { return }
            do { try await operation(c) } catch { if !Task.isCancelled { status = String(describing: error) } }
        }
    }

    func setLight(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        let color = LightbarColor(red: UInt8(max(0, min(1, rgb.redComponent)) * 255),
                                 green: UInt8(max(0, min(1, rgb.greenComponent)) * 255),
                                 blue: UInt8(max(0, min(1, rgb.blueComponent)) * 255))
        output { try await $0.setLightbar(color) }
    }

    func trigger(_ effect: TriggerEffect) { output { try await $0.apply(OutputState(leftTrigger: effect, rightTrigger: effect)) } }
    func haptic(_ effect: HapticEffect) { output { try await $0.play(effect) } }
    func player(_ n: Int) { output { try await $0.setPlayerLEDs(.player(n)) } }

}

struct ContentView: View {
    @Bindable var model: DemoModel

    var body: some View {
        Form {
            Section("Status") {
                Text(model.status)
                if model.permission != .granted {
                    HStack {
                        Text("Input Monitoring: \(model.permission.rawValue)").foregroundStyle(.red)
                        Button("Open Settings") { InputMonitoringPermission.openSystemSettings() }
                    }
                }
                if let g = model.gcName { Text("GameController match: \(g)").font(.caption) }
            }
            if let s = model.input {
                Section("Input") {
                    Text("Left (\(s.leftStick.x), \(s.leftStick.y))  Right (\(s.rightStick.x), \(s.rightStick.y))  L2 \(s.l2)  R2 \(s.r2)")
                        .monospacedDigit()
                    Text("Buttons: 0x\(String(s.buttons.rawValue, radix: 16))").monospaced()
                    if let imu = model.imu {
                        Text(String(format: "Gyro %.0f %.0f %.0f °/s   Accel %.2f %.2f %.2f g",
                                    imu.gyroDegPerSec.x, imu.gyroDegPerSec.y, imu.gyroDegPerSec.z,
                                    imu.accelG.x, imu.accelG.y, imu.accelG.z)).monospacedDigit()
                    }
                    if let b = s.battery { Text("Battery \(b.percent)% (\(b.charging.rawValue))") }
                }
            }
            Section("Lightbar & LEDs") {
                ColorPicker("Lightbar", selection: $model.color).onChange(of: model.color) { _, c in model.setLight(c) }
                HStack { ForEach(1...5, id: \.self) { n in Button("P\(n)") { model.player(n) } } }
            }
            Section("Adaptive triggers") {
                HStack {
                    Button("Off") { model.trigger(.off) }
                    Button("Feedback") { model.trigger((try? .feedback(position: 2, strength: 6)) ?? .off) }
                    Button("Weapon") { model.trigger((try? .weapon(start: 3, end: 6, strength: 8)) ?? .off) }
                    Button("Vibration") { model.trigger((try? .vibration(position: 2, amplitude: 6, frequency: 30)) ?? .off) }
                    Button("Bow*") { model.trigger((try? .bow(start: 1, end: 6, strength: 6, snapForce: 8)) ?? .off) }
                    Button("Machine*") { model.trigger((try? .machine(start: 2, end: 9, amplitudeA: 3, amplitudeB: 7, frequency: 8, period: 4)) ?? .off) }
                }
                Text("* unofficial effects").font(.caption)
            }
            Section("Haptics (Bluetooth)") {
                HStack {
                    Button("Click") { model.haptic(.click()) }
                    Button("Detent") { model.haptic(.detent()) }
                    Button("Texture") { model.haptic(.texture(duration: 1)) }
                    Button("Impact") { model.haptic(.impact()) }
                }
                if !model.metrics.isEmpty { Text(model.metrics).font(.caption.monospaced()) }
            }
        }
        .formStyle(.grouped)
    }
}
