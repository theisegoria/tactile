public import TactileCore

/// Errors surfaced by the transport layer.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The host process lacks the Input Monitoring permission. Call
    /// `InputMonitoringPermission.request()` or send the user to
    /// `InputMonitoringPermission.settingsURL`.
    case inputMonitoringDenied
    case deviceUnavailable
    case notSupported(String)
    case exclusiveAccessHeldByAnotherProcess
    case ioFailure(String)
    case timeout
    case parse(ParseError)
    case closed

    public var description: String {
        switch self {
        case .inputMonitoringDenied:
            "Input Monitoring permission is required. Enable it in System Settings › Privacy & Security › Input Monitoring."
        case .deviceUnavailable: "The controller is not connected."
        case .notSupported(let s): "Not supported: \(s)"
        case .exclusiveAccessHeldByAnotherProcess: "Another process has exclusive access to the controller."
        case .ioFailure(let s): "HID I/O failed: \(s)"
        case .timeout: "The controller did not respond in time."
        case .parse(let e): "Malformed report: \(e)"
        case .closed: "The connection is closed."
        }
    }
}
