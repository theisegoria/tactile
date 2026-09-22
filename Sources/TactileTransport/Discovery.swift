public import CoreHID
import TactileCore
import Foundation

/// Discovery events.
public enum DiscoveryEvent: Sendable {
    case connected(DeviceInfo, HIDDeviceClient.DeviceReference)
    case disconnected(deviceID: UInt64)
}

/// Watches for DualSense / DualSense Edge HID devices via CoreHID.
public final class DeviceDiscovery: Sendable {
    private let manager = HIDDeviceManager()

    public init() {}

    /// The matching criteria for both supported product IDs.
    public static let criteria: [HIDDeviceManager.DeviceMatchingCriteria] = [
        .init(vendorID: DeviceIDs.sonyVendorID, productID: DeviceIDs.dualSenseProductID),
        .init(vendorID: DeviceIDs.sonyVendorID, productID: DeviceIDs.dualSenseEdgeProductID),
    ]

    /// Streams connect/disconnect events. Devices already attached are reported
    /// first as `.connected`. The stream ends if CoreHID reports an error.
    public func events(includeVirtual: Bool = false) -> AsyncThrowingStream<DiscoveryEvent, any Error> {
        let manager = self.manager
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await n in await manager.monitorNotifications(matchingCriteria: Self.criteria) {
                        switch n {
                        case .deviceMatched(let ref):
                            guard let info = await Self.describe(ref) else { continue }
                            if info.isVirtual && !includeVirtual { continue }
                            continuation.yield(.connected(info, ref))
                        case .deviceRemoved(let ref):
                            continuation.yield(.disconnected(deviceID: ref.deviceID))
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot of currently attached controllers (waits `settle` for enumeration).
    public func currentDevices(includeVirtual: Bool = false, settle: Duration = .milliseconds(400)) async throws
        -> [(DeviceInfo, HIDDeviceClient.DeviceReference)]
    {
        let stream = events(includeVirtual: includeVirtual)
        let collector = Task { () -> [(DeviceInfo, HIDDeviceClient.DeviceReference)] in
            var found: [(DeviceInfo, HIDDeviceClient.DeviceReference)] = []
            do {
                for try await e in stream {
                    if case .connected(let i, let r) = e { found.append((i, r)) }
                    if Task.isCancelled { break }
                }
            } catch {}
            return found
        }
        try await Task.sleep(for: settle)
        collector.cancel()
        return await collector.value
    }

    /// Reads identifying properties from a device reference.
    public static func describe(_ ref: HIDDeviceClient.DeviceReference) async -> DeviceInfo? {
        guard let client = HIDDeviceClient(deviceReference: ref) else { return nil }
        return await describe(client)
    }

    public static func describe(_ client: HIDDeviceClient) async -> DeviceInfo? {
        guard let model = ControllerModel(vendorID: await client.vendorID, productID: await client.productID) else {
            return nil
        }
        let hidTransport = await client.transport
        let transport: Transport
        var isVirtual = false
        switch hidTransport {
        case .usb?: transport = .usb
        case .bluetooth?, .bluetoothLowEnergy?, .bluetoothAACP?: transport = .bluetooth
        case .virtual?:
            transport = .bluetooth
            isVirtual = true
        default: transport = .bluetooth
        }
        let virtualProperty = await client["HIDVirtualDevice"]
        if Self.truthy(virtualProperty) { isVirtual = true }
        return DeviceInfo(
            deviceID: client.deviceReference.deviceID, model: model, transport: transport,
            product: await client.product, serialNumber: await client.serialNumber,
            locationID: await client.locationID, reportDescriptor: await client.descriptor, isVirtual: isVirtual)
    }

    private static func truthy(_ p: HIDDeviceClient.UnsafeProperty?) -> Bool {
        guard let o = p?.unsafeObject else { return false }
        if let n = o as? NSNumber { return n.boolValue }
        return false
    }
}
