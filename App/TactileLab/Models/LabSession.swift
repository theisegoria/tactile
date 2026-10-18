import AppKit
import AVFoundation
import Foundation
import Observation
import Tactile

@MainActor @Observable
final class LiveReadings {
    var input: InputState?
    var imu: CalibratedIMU?
    var rate = 0.0
    var reportCount: UInt64 = 0
    var raw: [RawReportRow] = []
    func clear() { input = nil; imu = nil; rate = 0; reportCount = 0; raw = [] }
}

/// Per-controller readings for the Players tab, kept apart from the session so
/// 15 Hz updates only redraw the player cards.
@MainActor @Observable
final class PlayerBoard {
    var readings: [String: PlayerReading] = [:]
    /// Controllers currently flashing their "identify" highlight.
    var identifying: Set<String> = []
    func clear() { readings = [:]; identifying = [] }
}

@MainActor @Observable
final class LabSession {
    let readings = LiveReadings()
    let board = PlayerBoard()
    /// Player numbers for local multiplayer / split screen.
    private(set) var slots = PlayerSlots(capacity: 4)
    /// Show each player's number and colour on the controllers. Off by default:
    /// the lab never drives outputs the user did not ask for.
    private(set) var playerLights = false
    private var assigner: PlayerAssigner?
    private var boardTasks: [String: Task<Void, Never>] = [:]
    var tab: LabTab = .input
    private(set) var devices: [LabDevice] = []
    private(set) var selectedID: String?
    private(set) var permission: InputMonitoringPermission.Status = .notDetermined
    private(set) var microphonePermission = AVAuthorizationStatus.notDetermined
    private(set) var status = "Ready to connect"
    private(set) var activeOperation: String?
    private(set) var errorMessage: String?
    private(set) var diagnostics = LabDiagnostics()
    private(set) var operations: [OperationReceipt] = []
    var observations = GuidedCheck.all.map { GuidedObservation(id: $0.id, title: $0.title) }
    private(set) var snapshots: [FeatureSnapshot] = []
    private(set) var candidates: [UplinkCandidate] = []
    private(set) var recordings: [String] = []
    var duration = 3.0
    var exclusive = false
    private(set) var appliedExclusive = false
    private(set) var simulated: Bool
    let scenario: String
    private(set) var transitioning = false
    private var controllers: [String: Controller] = [:]
    private var addresses: [String: MACAddress] = [:]
    private var bridge: ControllerBridge?
    private let output = ControllerOperations()
    private var manager: ControllerManager?
    private var managerGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var microphonePermissionTask: Task<Void, Never>?
    private var started = false
    private var observationHistory: [GuidedObservation] = []

    init(simulated: Bool = ProcessInfo.processInfo.arguments.contains("--simulate") || ProcessInfo.processInfo.environment["TACTILE_SIMULATED"] == "1", scenario: String? = nil) {
        self.simulated = simulated
        let arguments = ProcessInfo.processInfo.arguments
        if let scenario { self.scenario = scenario }
        else if let index = arguments.firstIndex(of: "--scenario"), index + 1 < arguments.count { self.scenario = arguments[index + 1] }
        else { self.scenario = "connected" }
    }

    var selectedDevice: LabDevice? { devices.first { $0.id == selectedID } }
    var canOperate: Bool { selectedDevice?.connected == true && !transitioning }
    var selectedController: Controller? { selectedID.flatMap { controllers[$0] } }

    func start() async {
        guard !started else { return }
        started = true
        await reconnect()
    }

    func refreshPermissions() {
        permission = simulated ? (scenario == "denied" ? .denied : .granted) : InputMonitoringPermission.status
        microphonePermission = simulated ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermission() {
        guard !simulated else { status = "Simulated permission denial; no system request made."; return }
        _ = InputMonitoringPermission.request()
        refreshPermissions()
        if permission == .granted { Task { await reconnect() } }
    }

    func setSimulation(_ enabled: Bool) async { simulated = enabled; await reconnect() }

    func reconnect() async {
        managerGeneration &+= 1
        let epoch = managerGeneration
        transitioning = true
        eventTask?.cancel(); inputTask?.cancel(); selectionTask?.cancel(); diagnosticsTask?.cancel()
        await stopAll()
        await output.select(nil)
        await manager?.shutdown()
        guard epoch == managerGeneration else { return }
        for address in addresses.values { bridge?.hidDeviceDisconnected(address) }
        addresses = [:]; controllers = [:]; devices = []; selectedID = nil
        readings.clear(); diagnostics = LabDiagnostics(); candidates = []; snapshots = []
        stopBoard()
        slots = PlayerSlots(capacity: slots.capacity)
        refreshPermissions()
        transitioning = false
        if simulated {
            if scenario == "denied" { status = "Simulated Input Monitoring denial"; return }
            if scenario == "no-device" { status = "Simulated: no Bluetooth controllers"; return }
            devices = [LabDevice(id: "simulated-edge", name: "Simulated DualSense Edge", model: "DualSense Edge", transport: "bluetooth", connected: true, simulated: true)]
            if scenario == "multiple" || scenario == "stale" || scenario == "split" {
                devices.append(LabDevice(id: "simulated-dualsense", name: "Simulated DualSense", model: "DualSense", transport: "bluetooth", connected: true, simulated: true))
            }
            if scenario == "split" {
                // Four players: the fourth has disconnected and its seat is held.
                devices.append(LabDevice(id: "simulated-dualsense-3", name: "Simulated DualSense", model: "DualSense", transport: "bluetooth", connected: true, simulated: true))
                devices.append(LabDevice(id: "simulated-dualsense-4", name: "Simulated DualSense", model: "DualSense", transport: "bluetooth", connected: false, simulated: true))
            }
            for device in devices { _ = slots.connect(device.id) }
            for device in devices where !device.connected { _ = slots.disconnect(device.id) }
            startSimulatedBoard(epoch: epoch)
            select(devices[0].id)
            return
        }
        guard permission != .denied else { status = "Input Monitoring is denied. Enable Tactile Lab in System Settings, then retry."; return }
        if bridge == nil { bridge = ControllerBridge() }
        var options = ConnectionOptions()
        options.mode = exclusive ? .exclusive : .shared
        appliedExclusive = exclusive
        options.allowedTransports = [.bluetooth]
        options.restoreOutputOnReconnect = false
        let manager = ControllerManager(options: options)
        self.manager = manager
        var playerOptions = PlayerOptions()
        playerOptions.capacity = slots.capacity
        playerOptions.applyLights = playerLights
        assigner = PlayerAssigner(options: playerOptions)
        status = "Looking for a Bluetooth DualSense…"
        eventTask = Task { [weak self] in
            for await event in manager.events() {
                guard let self, !Task.isCancelled, self.managerGeneration == epoch else { return }
                await self.handle(event, epoch: epoch)
            }
        }
    }

    private func handle(_ event: ControllerEvent, epoch: UInt64) async {
        switch event {
        case .connected(let controller), .reconnected(let controller):
            controllers[controller.id] = controller
            let device = LabDevice(id: controller.id, name: controller.model.displayName, model: controller.model.displayName,
                                   transport: controller.transport.rawValue, connected: true, simulated: false)
            if let index = devices.firstIndex(where: { $0.id == controller.id }) { devices[index] = device }
            else { devices.append(device) }
            if let assigner { assigner.handle(event); slots = assigner.slots }
            startBoard(for: controller, epoch: epoch)
            if let address = await controller.address {
                guard managerGeneration == epoch else { return }
                addresses[controller.id] = address
                bridge?.hidDeviceConnected(address)
            }
            if selectedID == nil || selectedID == controller.id { select(controller.id) }
        case .disconnected(let controller):
            if let index = devices.firstIndex(where: { $0.id == controller.id }) { devices[index].connected = false }
            if let assigner { assigner.handle(event); slots = assigner.slots }
            boardTasks.removeValue(forKey: controller.id)?.cancel()
            if let address = addresses.removeValue(forKey: controller.id) { bridge?.hidDeviceDisconnected(address) }
            if selectedID == controller.id { select(controller.id); status = "Disconnected. Waiting for the selected controller." }
        case .failed(let info, let error):
            errorMessage = "\(info.model.displayName): \(error)"
            status = "Connection failed. Check permission, Bluetooth pairing, and other apps using exclusive access."
            refreshPermissions()
        }
    }

    func select(_ id: String?) {
        if id != selectedID || observations.contains(where: { $0.simulated != simulated && $0.observedAt != nil }) {
            observationHistory.append(contentsOf: observations.filter { $0.observedAt != nil })
            if observationHistory.count > 500 { observationHistory.removeFirst(observationHistory.count - 500) }
            observations = GuidedCheck.all.map { GuidedObservation(id: $0.id, title: $0.title) }
        }
        selectionGeneration &+= 1
        let epoch = selectionGeneration
        operationGeneration &+= 1
        microphonePermissionTask?.cancel(); microphonePermissionTask = nil
        outputTask?.cancel(); inputTask?.cancel(); selectionTask?.cancel(); diagnosticsTask?.cancel()
        activeOperation = nil
        selectedID = id
        readings.clear(); diagnostics = LabDiagnostics(); candidates = []; snapshots = []
        errorMessage = nil
        transitioning = true
        let target: LabTarget?
        if let id, selectedDevice?.connected == true {
            if simulated { target = .simulated(id, fails: scenario == "failure") }
            else { target = controllers[id].map(LabTarget.controller) }
        } else { target = nil }
        selectionTask = Task {
            guard !Task.isCancelled else { return }
            await output.select(target)
            guard !Task.isCancelled, selectionGeneration == epoch else { return }
            transitioning = false
            guard let target else { status = "No connected controller selected"; return }
            status = simulated ? "Simulated session — no hardware output" : "Connected over Bluetooth · \(appliedExclusive ? "Exclusive" : "Shared") access"
            if let controller = target.controller {
                refreshDiagnostics()
                inputTask = Task {
                    let stream = LiveMonitor.stream(for: controller) { [weak self] event in
                        guard let self, self.selectionGeneration == epoch, let address = self.addresses[controller.id] else { return }
                        self.bridge?.hidInput(address, buttons: event.state.buttons)
                        let match = self.bridge?.controller(for: address)?.vendorName ?? "No match; press buttons to correlate"
                        if self.diagnostics.gameController != match { self.diagnostics.gameController = match }
                    }
                    for await snapshot in stream {
                        guard !Task.isCancelled, selectionGeneration == epoch else { return }
                        publish(snapshot)
                    }
                }
            } else {
                diagnostics.calibration = "Simulated calibrated values"
                diagnostics.gameController = "Simulated match"
                inputTask = Task {
                    var tick: UInt64 = 0
                    do {
                        while !Task.isCancelled, selectionGeneration == epoch {
                            tick &+= 1
                            publish(Simulation.snapshot(tick: tick, edge: target.id == "simulated-edge"))
                            try await Task.sleep(for: .milliseconds(34))
                        }
                    } catch {}
                }
            }
        }
    }

    private func publish(_ snapshot: LiveSnapshot) {
        readings.input = snapshot.input; readings.imu = snapshot.imu
        readings.reportCount = snapshot.reports; readings.rate = snapshot.rate
        if readings.raw.last?.id != snapshot.raw.last?.id { readings.raw = snapshot.raw }
        if diagnostics.reportRate != snapshot.rate || snapshot.reports / 240 != diagnostics.reportsReceived / 240 {
            diagnostics.reportRate = snapshot.rate
            diagnostics.reportsReceived = snapshot.reports
            if !snapshot.metrics.isEmpty { diagnostics.metrics = snapshot.metrics }
        }
    }

    func refreshDiagnostics() {
        guard let controller = selectedController else { return }
        let epoch = selectionGeneration
        diagnosticsTask?.cancel()
        diagnosticsTask = Task {
            var result = await DiagnosticsService.collect(controller)
            guard !Task.isCancelled, selectionGeneration == epoch else { return }
            result.reportRate = readings.rate; result.reportsReceived = readings.reportCount
            result.gameController = diagnostics.gameController
            diagnostics = result
        }
    }

    func perform(_ command: LabCommand, name: String, settings: String, guidedID: String? = nil) {
        guard canOperate, let selectedID else { errorMessage = LabError.noController.localizedDescription; return }
        guard duration.isFinite, (0.1...60).contains(duration) else { errorMessage = "Duration must be 0.1–60 seconds."; return }
        operationGeneration &+= 1
        microphonePermissionTask?.cancel(); microphonePermissionTask = nil
        let epoch = operationGeneration
        outputTask?.cancel()
        let receipt = OperationReceipt(deviceID: selectedID, name: name, requestedSettings: "\(settings); duration=\(duration)s", simulated: simulated, diagnostics: diagnostics)
        operations.append(receipt)
        if operations.count > 500 { operations.removeFirst(operations.count - 500) }
        if let guidedID, let index = observations.firstIndex(where: { $0.id == guidedID }) {
            observations[index].operationID = receipt.id
            observations[index].deviceID = selectedID
            observations[index].simulated = simulated
            observations[index].result = .unverified
            observations[index].diagnostics = diagnostics
        }
        activeOperation = name; errorMessage = nil
        let duration = duration
        outputTask = Task {
            do {
                try Task.checkCancellation()
                let result = try await output.perform(command, duration: duration)
                finish(receipt.id, result: result.summary, metrics: result.metrics)
                if let index = operations.firstIndex(where: { $0.id == receipt.id }) {
                    operations[index].candidateLayouts = result.candidates
                    operations[index].reportCounts = result.reportCounts
                }
                guard operationGeneration == epoch else { return }
                if !result.metrics.isEmpty { diagnostics.metrics = result.metrics }
                candidates = result.candidates.isEmpty ? candidates : result.candidates
                if let recording = result.recording { recordings.append(recording.path) }
                status = result.summary
            } catch is CancellationError {
                finish(receipt.id, result: "Cancelled; cleanup requested", metrics: [:])
            } catch {
                let message = Self.describe(error)
                finish(receipt.id, result: "Failed: \(message)", metrics: [:])
                if operationGeneration == epoch { errorMessage = message }
            }
            if operationGeneration == epoch { activeOperation = nil }
        }
    }

    func requestHostMicrophoneHaptics(gain: Float) {
        guard canOperate, gain.isFinite, (0...4).contains(gain) else { return }
        microphonePermissionTask?.cancel()
        let epoch = operationGeneration
        let deviceID = selectedID
        microphonePermissionTask = Task {
            guard !Task.isCancelled else { return }
            let permitted = simulated ? true : await AVCaptureDevice.requestAccess(for: .audio)
            // A system permission prompt cannot be withdrawn. Stop All,
            // another output request, or a device change must invalidate its
            // completion without waiting for the user to answer that prompt.
            guard !Task.isCancelled, operationGeneration == epoch,
                  selectedID == deviceID, canOperate else { return }
            refreshPermissions()
            guard permitted else {
                showError(LabError.invalid("Allow Microphone access in System Settings → Privacy & Security → Microphone."))
                return
            }
            perform(.hostMicrophone(gain), name: "Host microphone haptics", settings: "host microphone, gain=\(gain)")
        }
    }

    private func finish(_ id: UUID, result: String, metrics: [String: Double]) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].finishedAt = Date(); operations[index].transportResult = result
        if !metrics.isEmpty {
            operations[index].diagnostics?.metrics = metrics
        }
    }

    func stopAll() async {
        operationGeneration &+= 1
        microphonePermissionTask?.cancel(); microphonePermissionTask = nil
        let epoch = operationGeneration
        let previous = outputTask
        previous?.cancel()
        activeOperation = "Stopping…"
        await output.stop()
        await previous?.value
        guard operationGeneration == epoch else { return }
        activeOperation = nil
        status = simulated ? "Simulated outputs stopped" : "Outputs reset to neutral"
    }

    func shutdown() async {
        stopBoard()
        managerGeneration &+= 1; selectionGeneration &+= 1
        eventTask?.cancel(); selectionTask?.cancel(); inputTask?.cancel(); diagnosticsTask?.cancel()
        await stopAll()
        await output.select(nil)
        await manager?.shutdown()
        started = false
    }

    func captureSnapshot(label: String) {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let epoch = selectionGeneration
        if simulated {
            snapshots.append(FeatureSnapshot(label: "Simulated: \(label)", reports: [0x20: [0x20, UInt8(snapshots.count % 256)]]))
            if snapshots.count > 20 { snapshots.removeFirst() }
            return
        }
        guard let controller = selectedController else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task {
            let collector = Task.detached { await controller.featureSnapshot(label: label) }
            let snapshot = await withTaskCancellationHandler {
                await collector.value
            } onCancel: { collector.cancel() }
            guard !Task.isCancelled, selectionGeneration == epoch else { return }
            snapshots.append(snapshot)
            if snapshots.count > 20 { snapshots.removeFirst() }
        }
    }

    func observe(_ check: String, result: ObservationResult, notes: String) {
        guard let index = observations.firstIndex(where: { $0.id == check }) else { return }
        observations[index].result = result; observations[index].notes = notes
        observations[index].observedAt = Date(); observations[index].deviceID = selectedID
        if let operation = observations[index].operationID,
           !operations.contains(where: { $0.id == operation && $0.deviceID == selectedID && $0.simulated == simulated }) {
            observations[index].operationID = nil
        }
        observations[index].simulated = simulated; observations[index].diagnostics = diagnostics
    }

    func report() -> SessionReport {
        var currentDiagnostics = diagnostics
        currentDiagnostics.reportRate = readings.rate; currentDiagnostics.reportsReceived = readings.reportCount
        return SessionReport(schemaVersion: 1, exportedAt: Date(), appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                             libraryVersion: TactileVersion.string, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                             simulated: simulated, devices: devices, selectedDeviceID: selectedID, accessMode: appliedExclusive ? "exclusive" : "shared",
                             diagnostics: currentDiagnostics, operations: operations, observations: observationHistory + observations, snapshots: snapshots,
                             rawReports: readings.raw, recordings: recordings)
    }

    func exportReport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Export Session"
        panel.message = "Choose a folder for session.json and summary.md. WAV files remain separate."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let report = report()
        let destination = directory.appendingPathComponent("Tactile Lab \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))")
        Task {
            do { try await DiagnosticsService.export(report, to: destination); status = "Exported session to \(destination.path)" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func clearError() { errorMessage = nil }
    func showError(_ error: any Error) { errorMessage = Self.describe(error) }
    private static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - Players (local multiplayer / split screen)

extension LabSession {
    func player(of id: String) -> Int? { slots.player(of: id) }
    func device(forPlayer player: Int) -> LabDevice? { slots.id(of: player).flatMap { id in devices.first { $0.id == id } } }
    func playerColor(_ player: Int) -> LightbarColor { LightbarColor.player(player) }

    /// Moves a controller to another player slot, swapping with its occupant.
    func assignPlayer(_ id: String, to player: Int) {
        if simulated {
            _ = slots.assign(id, to: player, connected: devices.first { $0.id == id }?.connected ?? false)
        } else if let assigner, let controller = controllers[id] {
            assigner.assign(controller, to: player)
            slots = assigner.slots
        }
        status = "Moved \(devices.first { $0.id == id }?.displayName ?? id) to player \(player)"
    }

    /// Frees a held seat (for example a player who left the session).
    func releasePlayer(_ player: Int) {
        if simulated { _ = slots.release(player: player) }
        else if let assigner { assigner.release(player: player); slots = assigner.slots }
    }

    func setPlayerLights(_ enabled: Bool) {
        playerLights = enabled
        assigner?.update { $0.applyLights = enabled }
        status = enabled
            ? (simulated ? "Simulated: player lights would be shown on each controller" : "Showing player numbers and colours on the controllers")
            : "Player lights off; controllers keep their current lights"
    }

    /// A short rumble on one controller, so a person can tell which is which.
    func identify(_ id: String) {
        board.identifying.insert(id)
        let controller = simulated ? nil : controllers[id]
        Task {
            if let controller { try? await controller.setRumble(Rumble(left: 150, right: 150)) }
            try? await Task.sleep(for: .milliseconds(350))
            if let controller { try? await controller.setRumble(.off) }
            board.identifying.remove(id)
        }
    }

    /// Opens a controller in the single-controller tabs.
    func inspect(_ id: String) {
        select(id)
        tab = .input
    }

    fileprivate func startBoard(for controller: Controller, epoch: UInt64) {
        boardTasks[controller.id]?.cancel()
        let id = controller.id
        boardTasks[id] = Task { [weak self] in
            var last = ContinuousClock.now
            var count = 0
            var rateStart = ContinuousClock.now
            var rate = 0.0
            for await event in await controller.inputEvents() {
                guard !Task.isCancelled else { return }
                count += 1
                let now = ContinuousClock.now
                if now - rateStart >= .seconds(1) {
                    rate = Double(count) / (now - rateStart).secondsValue
                    count = 0; rateStart = now
                }
                guard now - last >= .milliseconds(66) else { continue }  // ≈15 Hz is plenty for cards
                last = now
                guard let self, self.managerGeneration == epoch else { return }
                self.board.readings[id] = PlayerReading(event.state, rate: rate)
            }
        }
    }

    fileprivate func startSimulatedBoard(epoch: UInt64) {
        boardTasks["simulated"]?.cancel()
        boardTasks["simulated"] = Task { [weak self] in
            var tick: UInt64 = 0
            while !Task.isCancelled {
                guard let self, self.managerGeneration == epoch, self.simulated else { return }
                tick &+= 2
                for (index, device) in self.devices.enumerated() where device.connected {
                    let snap = Simulation.snapshot(tick: tick &+ UInt64(index * 47), edge: device.id == "simulated-edge")
                    if let input = snap.input { self.board.readings[device.id] = PlayerReading(input, rate: snap.rate) }
                }
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    fileprivate func stopBoard() {
        for task in boardTasks.values { task.cancel() }
        boardTasks = [:]
        board.clear()
    }
}
