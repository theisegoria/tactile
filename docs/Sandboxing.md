# Sandboxing and entitlements

Entitlements belong to the **main executable**; a framework or dylib (including
`libCTactile.dylib` and the XCFramework) cannot carry them. Host apps must add:

| Distribution | Entitlements |
|---|---|
| Developer ID (hardened runtime, not sandboxed) | none required for HID; `com.apple.security.device.audio-input` for mic haptics |
| Mac App Store (sandboxed) | `com.apple.security.app-sandbox`, `com.apple.security.device.bluetooth`, `com.apple.security.device.usb` (for USB), `com.apple.security.device.audio-input` (mic haptics) |

Both files ship with the sample: `Samples/SwiftSample/Support/*.entitlements`.

Evidence that sandboxed distribution is possible: the Mac App Store app DualSenseM
controls triggers, player LEDs and the lightbar over Bluetooth. Its exact entitlement
set is **unverified** (TESTING.md 4.3 verifies Tactile's).

Not used: `com.apple.developer.hid.virtual.device` (system-wide virtual controller;
restricted, paid program, no development variant — out of scope, see
`docs/Architecture.md#virtual-device-seam`).
