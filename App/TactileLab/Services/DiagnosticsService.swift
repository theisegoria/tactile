import Foundation
import Tactile

enum DiagnosticsService {
    static func collect(_ controller: Controller) async -> LabDiagnostics {
        await Task.detached {
            var result = LabDiagnostics()
            result.firmware = await controller.firmware
            result.descriptor = controller.reportDescriptor?.reports ?? []
            if let conflicts = controller.conflicts() {
                result.conflicts = conflicts.otherClients.map(\.description)
                result.virtualTwins = conflicts.virtualTwins
            }
            result.calibration = await controller.calibration?.isFromDevice == true ? "Factory calibration" : "Nominal calibration; factory data unavailable"
            result.metrics = metricValues(controller.hapticsMetrics())
            return result
        }.value
    }

    static func export(_ report: SessionReport, to directory: URL) async throws {
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            try markdown(report).write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }.value
    }

    static func markdown(_ report: SessionReport) -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
        var text = """
        # Tactile Lab session

        Schema: \(report.schemaVersion) · App: \(report.appVersion) · Library: \(report.libraryVersion)
        OS: \(report.operatingSystem)
        Exported: \(report.exportedAt.formatted(.iso8601))
        Mode: \(report.simulated ? "SIMULATED — no hardware evidence" : "Physical controller") · Access: \(report.accessMode)
        Selected device: \(report.selectedDeviceID ?? "None")

        Successful HID transmission does not establish a felt or heard result. Only explicitly recorded human observations count as Pass or Fail. Experimental audio remains unverified unless a physical observation establishes it.

        ## Devices

        """
        for device in report.devices { text += "- \(device.name) · \(device.id) · \(device.transport) · \(device.connected ? "connected" : "disconnected")\n" }
        if let firmware = report.diagnostics.firmware { text += "\nFirmware: \(firmware.updateVersionString) (\(firmware.firmwareVersion))\n" }
        text += "\n## Observations\n\n| Check | Result | Device | Notes |\n|---|---|---|---|\n"
        for observation in report.observations {
            text += "| \(cell(observation.title)) | \(observation.result.rawValue)\(observation.simulated ? " (simulated)" : "") | \(cell(observation.deviceID ?? "—")) | \(cell(observation.notes)) |\n"
        }
        text += "\n## Operations\n"
        for operation in report.operations {
            text += "\n### \(operation.name)\n\nDevice: \(operation.deviceID)\n\nRequested: \(operation.requestedSettings)\n\nTransport: \(operation.transportResult)\n"
        }
        text += "\n## Diagnostics\n\nInput: \(report.diagnostics.reportsReceived) reports, \(report.diagnostics.reportRate.formatted(.number.precision(.fractionLength(1)))) Hz\n\nCalibration: \(report.diagnostics.calibration)\n\nGameController: \(report.diagnostics.gameController)\n\nConflicts: \(report.diagnostics.conflicts.joined(separator: ", "))\n"
        for (name, value) in report.diagnostics.metrics.sorted(by: { $0.key < $1.key }) { text += "- \(name): \(value)\n" }
        text += "\nWAV recordings are saved separately and are not embedded in this report.\n"
        for recording in report.recordings { text += "- \(recording)\n" }
        return text
    }
}
