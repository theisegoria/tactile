/// Identification constants and device models.

public enum DeviceIDs {
    public static let sonyVendorID: UInt32 = 0x054C
    public static let dualSenseProductID: UInt32 = 0x0CE6
    public static let dualSenseEdgeProductID: UInt32 = 0x0DF2
}

/// The controller model, identified by product ID (never by report descriptor;
/// the Edge's Bluetooth descriptor has been seen to masquerade as a DualSense).
public enum ControllerModel: String, Sendable, CaseIterable, Codable {
    case dualSense
    case dualSenseEdge

    public init?(vendorID: UInt32, productID: UInt32) {
        guard vendorID == DeviceIDs.sonyVendorID else { return nil }
        switch productID {
        case DeviceIDs.dualSenseProductID: self = .dualSense
        case DeviceIDs.dualSenseEdgeProductID: self = .dualSenseEdge
        default: return nil
        }
    }

    public var productID: UInt32 {
        switch self {
        case .dualSense: DeviceIDs.dualSenseProductID
        case .dualSenseEdge: DeviceIDs.dualSenseEdgeProductID
        }
    }

    public var displayName: String {
        switch self {
        case .dualSense: "DualSense"
        case .dualSenseEdge: "DualSense Edge"
        }
    }
}

/// How the controller is attached.
public enum Transport: String, Sendable, Codable {
    case bluetooth
    case usb
}
