# Permissions

## Input Monitoring

macOS requires the **Input Monitoring** privacy permission (TCC service
`ListenEvent`) before a process can open a gamepad for raw HID access. SDL and
hidapi document that opens fail with `kIOReturnNotPermitted` without it; with
CoreHID, Tactile maps `HIDDeviceError.notPermitted` / `.notPrivileged` (and a
`nil` `HIDDeviceClient` while permission is not granted) to
`TransportError.inputMonitoringDenied` (C: `TACTILE_ERR_PERMISSION`).
*Unverified for CoreHID — see TESTING.md 0.5.*

API:

```swift
InputMonitoringPermission.status        // .granted / .denied / .notDetermined
InputMonitoringPermission.request()     // prompts once; later calls return the stored answer
InputMonitoringPermission.openSystemSettings()   // Tactile module, AppKit
InputMonitoringPermission.settingsURL   // x-apple.systempreferences:…?Privacy_ListenEvent
```

Notes for host apps:
- The permission belongs to the **responsible process**: when you run `tactilectl`
  from Terminal, Terminal needs it; for an app, the app bundle does.
- After granting, the process usually has to be relaunched.
- Unsigned or re-signed binaries get a new TCC identity; re-grant after re-signing.
- There is no Info.plist usage string for Input Monitoring.

## Microphone

Only for audio-reactive haptics from the microphone (`AudioTapSource` on
`engine.inputNode`): add `NSMicrophoneUsageDescription`, and
`com.apple.security.device.audio-input` for hardened-runtime/sandboxed apps.
