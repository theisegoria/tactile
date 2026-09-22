public import TactileCore
public import Foundation

/// A discovered controller, before or after opening.
public struct DeviceInfo: Sendable, Hashable, CustomStringConvertible {
    /// CoreHID registry ID. Changes on every reconnect.
    public var deviceID: UInt64
    public var model: ControllerModel
    public var transport: Transport
    public var product: String?
    /// For Bluetooth HID devices macOS reports the controller's MAC here
    /// ("02-11-22-33-44-55"). Cross-checked against feature report 0x09 on open.
    public var serialNumber: String?
    public var locationID: UInt64?
    public var reportDescriptor: Data
    /// True for virtual HID devices (e.g. Steam Input's virtual pads).
    public var isVirtual: Bool

    public init(deviceID: UInt64, model: ControllerModel, transport: Transport, product: String?,
                serialNumber: String?, locationID: UInt64?, reportDescriptor: Data, isVirtual: Bool) {
        self.deviceID = deviceID
        self.model = model
        self.transport = transport
        self.product = product
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.reportDescriptor = reportDescriptor
        self.isVirtual = isVirtual
    }

    /// MAC address derived from the serial number, when it has that shape.
    public var serialMAC: MACAddress? { serialNumber.flatMap(MACAddress.init(string:)) }

    public var description: String {
        "\(model.displayName) [\(transport.rawValue)] id=\(String(deviceID, radix: 16))"
            + (serialNumber.map { " serial=\($0)" } ?? "") + (isVirtual ? " (virtual)" : "")
    }
}
