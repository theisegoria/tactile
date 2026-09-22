// Gate 0 reconnaissance probe. Talks to CoreHID directly (not through
// DeviceConnection) so that it can observe the device's untouched behaviour,
// e.g. the switch from input report 0x01 to 0x31 after feature report 0x05.

import CoreHID
import Foundation
import GameController
import TactileCore
import TactileTransport

@main
struct Probe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let cmd = args.first ?? "help"
        log("tactile-probe \(cmd) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("Input Monitoring: \(InputMonitoringPermission.status.rawValue)")
        switch cmd {
        case "list": await list()
        case "reports": await reports(seconds: Double(args.dropFirst().first ?? "") ?? 3)
        case "features": await features()
        case "gc": await gameController(seconds: Double(args.dropFirst().first ?? "") ?? 8)
        case "conflicts": await conflicts()
        case "request-permission":
            log("IOHIDRequestAccess → \(InputMonitoringPermission.request())")
        default:
            print("""
            usage: tactile-probe <command>
              list                 enumerate controllers (incl. virtual) and dump report descriptors
              reports [seconds]    log raw input reports before and after reading feature 0x05
              features             dump feature reports 0x03, 0x05, 0x09, 0x20 (raw)
              gc [seconds]         exercise GameController: triggers, light, haptics, battery
              conflicts            list other processes holding the controller open
              request-permission   trigger the Input Monitoring prompt
            """)
        }
    }

    static func log(_ s: String) {
        let t = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        print("[\(t)] \(s)")
    }

    static func firstDevice() async -> (DeviceInfo, HIDDeviceClient)? {
        guard let devices = try? await DeviceDiscovery().currentDevices(includeVirtual: false), let d = devices.first else {
            log("No DualSense / DualSense Edge found. Connect one over Bluetooth and retry.")
            return nil
        }
        guard let client = HIDDeviceClient(deviceReference: d.1) else {
            log("HIDDeviceClient init returned nil (permission? device gone?)")
            return nil
        }
        return (d.0, client)
    }

    static func list() async {
        do {
            let devices = try await DeviceDiscovery().currentDevices(includeVirtual: true)
            log("Found \(devices.count) device(s)")
            for (info, _) in devices {
                log("• \(info)")
                log("  product=\(info.product ?? "?") location=\(info.locationID.map { String($0, radix: 16) } ?? "?")")
                log("  report descriptor (\(info.reportDescriptor.count) bytes):")
                let bytes = [UInt8](info.reportDescriptor)
                for chunk in stride(from: 0, to: bytes.count, by: 32) {
                    print("    " + Array(bytes[chunk..<min(chunk + 32, bytes.count)]).hexString)
                }
                log("  descriptor report IDs: \(DescriptorScan.reportIDs(bytes))")
            }
        } catch {
            log("Discovery failed: \(error)")
        }
    }

    static func reports(seconds: Double) async {
        guard let (info, client) = await firstDevice() else { return }
        log("Opened \(info)")
        let counter = ReportCounter()
        let monitor = Task {
            do {
                for try await n in await client.monitorNotifications(reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: []) {
                    if case .inputReport(let id, let data, _) = n {
                        await counter.record(id: id?.rawValue, data: [UInt8](data))
                    }
                }
            } catch {
                log("monitorNotifications error: \(error)")
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        log("Phase 1 (before 0x05): \(await counter.summary())")
        await counter.reset()
        do {
            let d = try await client.dispatchGetReportRequest(type: .feature, id: HIDReportID(rawValue: 0x05), timeout: .seconds(2))
            log("GET feature 0x05 → \(d.count) bytes: \([UInt8](d).hexString)")
        } catch {
            log("GET feature 0x05 failed: \(error)")
        }
        try? await Task.sleep(for: .seconds(seconds))
        log("Phase 2 (after 0x05): \(await counter.summary())")
        monitor.cancel()
    }

    static func features() async {
        guard let (info, client) = await firstDevice() else { return }
        log("Opened \(info)")
        for id: UInt8 in [0x03, 0x05, 0x09, 0x20] {
            do {
                let d = try await client.dispatchGetReportRequest(type: .feature, id: HIDReportID(rawValue: id), timeout: .seconds(2))
                let b = [UInt8](d)
                let crcOK = info.transport == .bluetooth ? " crcA3=\(CRC32.verify(b.first == id ? b : [id] + b, prefix: .feature))" : ""
                log("feature 0x\(String(id, radix: 16)) (\(b.count) bytes, starts-with-id=\(b.first == id))\(crcOK): \(b.hexString)")
            } catch {
                log("feature 0x\(String(id, radix: 16)) failed: \(error)")
            }
        }
    }

    static func conflicts() async {
        guard let (info, _) = await firstDevice() else { return }
        let r = ConflictDetector.scan(model: info.model, serialNumber: info.serialNumber)
        log("Other HID clients: \(r.otherClients.isEmpty ? "none" : r.otherClients.map(\.description).joined(separator: ", "))")
        log("Virtual twins (e.g. Steam Input): \(r.virtualTwins)")
    }
}

actor ReportCounter {
    var counts: [UInt8: Int] = [:]
    var lengths: [UInt8: Int] = [:]
    var samples: [UInt8: [UInt8]] = [:]
    var firstByteIsID = 0
    var total = 0

    func record(id: UInt8?, data: [UInt8]) {
        let rid = id ?? data.first ?? 0
        counts[rid, default: 0] += 1
        lengths[rid] = data.count
        if samples[rid] == nil { samples[rid] = data }
        if data.first == rid { firstByteIsID += 1 }
        total += 1
    }

    func reset() {
        counts = [:]; lengths = [:]; samples = [:]; firstByteIsID = 0; total = 0
    }

    func summary() -> String {
        var s = counts.keys.sorted().map { "0x\(String($0, radix: 16)): \(counts[$0] ?? 0) reports × \(lengths[$0] ?? 0) bytes" }
            .joined(separator: "; ")
        s += " | data[0]==id in \(firstByteIsID)/\(total)"
        for (k, v) in samples.sorted(by: { $0.key < $1.key }) {
            s += "\n    sample 0x\(String(k, radix: 16)): \(Array(v.prefix(80)).hexString)"
        }
        return s
    }
}

/// Minimal HID descriptor walk to list declared report IDs (tag 0x85).
enum DescriptorScan {
    static func reportIDs(_ d: [UInt8]) -> [String] {
        var ids: [String] = []
        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {  // long item
                guard i + 1 < d.count else { break }
                i += 3 + Int(d[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            if prefix & 0xFC == 0x84, size == 1, i + 1 < d.count {
                ids.append("0x" + String(d[i + 1], radix: 16))
            }
            i += 1 + size
        }
        return ids
    }
}
