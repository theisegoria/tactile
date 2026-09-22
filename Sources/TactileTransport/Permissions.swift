import IOKit.hid
public import Foundation

/// Input Monitoring (TCC "ListenEvent") permission, which macOS requires before a
/// process may open a gamepad for raw HID access. Without it opens fail with
/// kIOReturnNotPermitted (surfaced as `TransportError.inputMonitoringDenied`).
public enum InputMonitoringPermission {
    public enum Status: String, Sendable {
        case granted, denied, notDetermined
    }

    public static var status: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }

    /// Prompts the user (first time only). Returns true if access is granted.
    /// After a denial macOS does not prompt again; direct users to `settingsURL`.
    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Deep link to System Settings › Privacy & Security › Input Monitoring.
    /// Open it with `NSWorkspace.shared.open(_:)` (or `Controller.openInputMonitoringSettings()`).
    public static let settingsURL: URL? = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
}
