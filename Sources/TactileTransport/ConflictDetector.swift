import IOKit
public import TactileCore
import Foundation

/// Another process holding the same controller open.
public struct HIDClientProcess: Sendable, Hashable, CustomStringConvertible {
    public var pid: Int32
    public var name: String

    public enum Kind: String, Sendable { case gameControllerDaemon, steam, other }

    public var kind: Kind {
        let n = name.lowercased()
        if n.contains("gamecontroller") { return .gameControllerDaemon }
        if n.contains("steam") { return .steam }
        return .other
    }

    public var description: String { "\(name) (pid \(pid))" }
}

/// What the conflict detector found for one controller.
public struct ConflictReport: Sendable, Hashable {
    /// Other user-space processes with an open IOHIDLibUserClient on the device.
    /// Any of these *may* write output reports; since each report carries full
    /// state, the last writer wins.
    public var otherClients: [HIDClientProcess]
    /// Virtual HID devices with the same VID/PID (Steam Input creates these).
    public var virtualTwins: Int

    public init(otherClients: [HIDClientProcess], virtualTwins: Int) {
        self.otherClients = otherClients
        self.virtualTwins = virtualTwins
    }

    public var hasConflicts: Bool { !otherClients.isEmpty || virtualTwins > 0 }
}

/// Inspects the IORegistry to find other processes that have a controller open.
/// This is detection only; nothing is blocked. Read-only and side-effect free.
public enum ConflictDetector {
    public static func scan(model: ControllerModel, serialNumber: String?, ownPID: Int32? = nil) -> ConflictReport {
        var clients: Set<HIDClientProcess> = []
        var twins = 0
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else {
            return ConflictReport(otherClients: [], virtualTwins: 0)
        }
        matching["VendorID"] = DeviceIDs.sonyVendorID
        matching["ProductID"] = model.productID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return ConflictReport(otherClients: [], virtualTwins: 0)
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if boolProperty(service, "HIDVirtualDevice") {
                twins += 1
                continue
            }
            if let serialNumber, let s = stringProperty(service, "SerialNumber"),
               s.lowercased() != serialNumber.lowercased() {
                continue
            }
            for p in userClients(of: service) where p.pid != (ownPID ?? getpid()) {
                clients.insert(p)
            }
        }
        return ConflictReport(otherClients: clients.sorted { $0.pid < $1.pid }, virtualTwins: twins)
    }

    static func userClients(of service: io_registry_entry_t) -> [HIDClientProcess] {
        var out: [HIDClientProcess] = []
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            // "IOUserClientCreator" = "pid 123, processname"
            guard let creator = stringProperty(child, "IOUserClientCreator") else { continue }
            if let p = parseCreator(creator) { out.append(p) }
        }
        return out
    }

    /// Parses "pid 123, name".
    public static func parseCreator(_ s: String) -> HIDClientProcess? {
        guard s.hasPrefix("pid ") else { return nil }
        let rest = s.dropFirst(4)
        guard let comma = rest.firstIndex(of: ","), let pid = Int32(rest[..<comma]) else { return nil }
        let name = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return HIDClientProcess(pid: pid, name: name)
    }

    static func stringProperty(_ e: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    static func boolProperty(_ e: io_registry_entry_t, _ key: String) -> Bool {
        let v = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? NSNumber)?.boolValue ?? false
    }
}
