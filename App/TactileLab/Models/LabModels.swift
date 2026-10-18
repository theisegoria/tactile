import Foundation
import Tactile

enum LabTab: String, CaseIterable, Identifiable {
    case input = "Input", effects = "Effects", audio = "Audio", diagnostics = "Diagnostics", tests = "Tests"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .input: "gamecontroller"
        case .effects: "waveform.path"
        case .audio: "speaker.wave.2"
        case .diagnostics: "stethoscope"
        case .tests: "checklist"
        }
    }
}

struct LabDevice: Identifiable, Sendable, Equatable, Codable {
    let id: String
    var name: String
    var model: String
    var transport: String
    var connected: Bool
    var simulated: Bool
}

struct RawReportRow: Identifiable, Sendable, Codable {
    let id: UInt64
    let date: Date
    let reportID: UInt8
    let bytes: [UInt8]
    var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct LabDiagnostics: Sendable, Codable {
    var firmware: FirmwareInfo?
    var descriptor: [HIDReportInfo] = []
    var conflicts: [String] = []
    var virtualTwins = 0
    var calibration = "Not available"
    var gameController = "No match"
    var reportRate: Double = 0
    var reportsReceived: UInt64 = 0
    var metrics: [String: Double] = [:]
    var collectedAt = Date()
}

struct OperationReceipt: Identifiable, Sendable, Codable {
    var id = UUID()
    var startedAt = Date()
    var finishedAt: Date?
    var deviceID: String
    var name: String
    var requestedSettings: String
    var simulated: Bool
    var transportResult = "In progress"
    var diagnostics: LabDiagnostics?
    var candidateLayouts: [UplinkCandidate] = []
    var reportCounts: [UInt8: Int] = [:]
}

enum ObservationResult: String, CaseIterable, Codable {
    case unverified = "Unverified", pass = "Pass", fail = "Fail", skipped = "Skipped"
}

struct GuidedObservation: Identifiable, Sendable, Codable {
    var id: String
    var title: String
    var result: ObservationResult = .unverified
    var notes = ""
    var operationID: UUID?
    var observedAt: Date?
    var deviceID: String?
    var simulated = false
    var diagnostics: LabDiagnostics?
}

struct SessionReport: Sendable, Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let libraryVersion: String
    let operatingSystem: String
    let simulated: Bool
    let devices: [LabDevice]
    let selectedDeviceID: String?
    let accessMode: String
    let diagnostics: LabDiagnostics
    let operations: [OperationReceipt]
    let observations: [GuidedObservation]
    let snapshots: [FeatureSnapshot]
    let rawReports: [RawReportRow]
    let recordings: [String]
}

enum LabError: LocalizedError {
    case noController, invalid(String), simulatedFailure
    var errorDescription: String? {
        switch self {
        case .noController: "Select a connected Bluetooth controller."
        case .invalid(let reason): reason
        case .simulatedFailure: "Simulated output failure. Retry or select another simulated controller."
        }
    }
}

enum LabCommand: Sendable {
    case output(OutputState)
    case haptic(HapticEffect, HapticSide)
    case hapticFile(URL, Float)
    case hostMicrophone(Float)
    case speaker(URL, SpeakerAudioFraming, Int, Float, AudioSettings)
    case scan
    case record(UplinkExtractor, OpusStreamFormat, URL)
}

struct OperationResult: Sendable {
    var summary: String
    var candidates: [UplinkCandidate] = []
    var reportCounts: [UInt8: Int] = [:]
    var recording: URL?
    var metrics: [String: Double] = [:]
}

enum LabTarget: Sendable {
    case controller(Controller)
    case simulated(String, fails: Bool)
    var controller: Controller? { if case .controller(let c) = self { c } else { nil } }
    var id: String {
        switch self { case .controller(let c): c.id; case .simulated(let id, _): id }
    }
}

extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

func metricValues(_ metrics: HapticsMetrics?) -> [String: Double] {
    guard let m = metrics else { return [:] }
    return ["reportsBuilt": Double(m.reportsBuilt), "reportsSent": Double(m.reportsSent),
            "reportsDropped": Double(m.reportsDropped), "underrunTicks": Double(m.underrunTicks),
            "wakeLatenessP99Us": m.wakeLatenessP99Us, "tickIntervalStdDevUs": m.tickIntervalStdDevUs,
            "sendLatencyMeanUs": m.sendLatencyMeanUs, "sendLatencyP99Us": m.sendLatencyP99Us,
            "pumpCPUPercent": m.pumpCPUPercent, "bufferedMs": m.bufferedMs]
}
