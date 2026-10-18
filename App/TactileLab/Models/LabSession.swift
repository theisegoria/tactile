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

@MainActor @Observable
final class LabSession {
    let readings = LiveReadings()
    var tab: LabTab = .input
    private(set) var devices: [LabDevice] = []
    private(set) var selectedID: String?
    private(set) var permission = InputMonitoringPermission.notDetermined
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
        refreshPermissions()
        transitioning = false
        if simulated {
            if scenario == "denied" { status = "Simulated Input Monitoring denial"; return }
            if scenario == "no-device" { status = "Simulated: no Bluetooth controllers"; return }
            devices = [LabDevice(id: "simulated-edge", name: "Simulated DualSense Edge", model: "DualSense Edge", transport: "bluetooth", connected: true, simulated: true)]
            if scenario == "multiple" || scenario == "stale" {
                devices.append(LabDevice(id: "simulated-dualsense", name: "Simulated DualSense", model: "DualSense", transport: "bluetooth", connected: true, simulated: true))
            }
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
            if let address = await controller.address {
                guard managerGeneration == epoch else { return }
                addresses[controller.id] = address
                bridge?.hidDeviceConnected(address)
            }
            if selectedID == nil || selectedID == controller.id { select(controller.id) }
        case .disconnected(let controller):
            if let index = devices.firstIndex(where: { $0.id == controller.id }) { devices[index].connected = false }
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

    private func finish(_ id: UUID, result: String, metrics: [String: Double]) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].finishedAt = Date(); operations[index].transportResult = result
        if !metrics.isEmpty {
            operations[index].diagnostics?.metrics = metrics
        }
    }

    func stopAll() async {
        operationGeneration &+= 1
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
        if simulated { snapshots.append(FeatureSnapshot(label: "Simulated: \(label)", reports: [0x20: [0x20, UInt8(snapshots.count % 256)]])); return }
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
