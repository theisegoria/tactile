import AppKit
public import TactileTransport

extension InputMonitoringPermission {
    /// Opens System Settings › Privacy & Security › Input Monitoring.
    @MainActor
    @discardableResult
    public static func openSystemSettings() -> Bool {
        guard let url = settingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }
}
