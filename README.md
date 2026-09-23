# Tactile

**Full-feature Bluetooth support for DualSense and DualSense Edge controllers on macOS.**

Tactile is a Swift package (with a C ABI) that gives macOS apps and game engines the
parts of the DualSense feature set that Apple's GameController framework does not
expose: HD audio-haptics over Bluetooth, every adaptive-trigger effect, lightbar,
player and mute LEDs, calibrated IMU, and the Edge's paddles and Fn buttons.

It works *alongside* GameController: GameController keeps doing discovery and
standard input; Tactile talks to the controller's HID protocol directly for the rest.

> Status: 0.1.0, pre-release. All software gates (0–4) are built and unit-tested, but
> **nothing has been verified on a controller yet** — see `docs/receipts/` and the
> status column in `PROTOCOL.md`.

## What it can and cannot do

- ✅ Any app or engine that links Tactile gets the full feature set.
- ❌ It cannot add features to games that do not link it. That would need a
  system-wide virtual controller (restricted Apple entitlement
  `com.apple.developer.hid.virtual.device`); out of scope.

## Requirements

- macOS 15 or later (CoreHID), Apple silicon (Intel builds but is untested)
- Swift 6 toolchain (Xcode 16+)
- **Input Monitoring** permission for the host app (see `docs/Permissions.md`)

## Modules

| Module | Purpose |
|---|---|
| `TactileCore` | Pure protocol logic: CRC, report parsers/builders, trigger effects, calibration. No I/O. |
| `TactileTransport` | CoreHID discovery, report I/O, reconnects, shared/exclusive modes, permission checks. |
| `TactileHaptics` | Float PCM → 3 kHz 8-bit stereo, real-time 10.67 ms report pump, audio-tap and parametric sources. |
| `TactileBridge` | Pairs HID devices with `GCController`s by Bluetooth MAC address. |
| `TactileAudio` | **Experimental.** Speaker/headphone audio (Opus, report 0x36) and microphone uplink research, via the system Opus codec. |
| `Tactile` | High-level `Controller` facade. |
| `CTactile` | C ABI (`include/tactile.h`) for engines and non-Swift hosts. |
| `tactilectl` | CLI demo and hardware test harness. |

## Quick start

```swift
import Tactile

let manager = ControllerManager()          // shared mode by default
for await controller in manager.connectedControllers() {
    try await controller.setLightbar(LightbarColor(red: 255, green: 0, blue: 128))
    try await controller.setTrigger(.right, try .weapon(start: 3, end: 6, strength: 8))
    try await controller.play(.click())      // Bluetooth audio haptics

    for await event in await controller.inputEvents() {
        if event.state.buttons.contains(.paddleLeft) { /* DualSense Edge paddle */ }
    }
}
```

```bash
swift run tactilectl permission           # grant Input Monitoring to your terminal
swift run tactilectl info
swift run tactilectl trigger right weapon 3 6 8
swift run tactilectl haptic --effect click
```

## Documentation

- `PROTOCOL.md` — every protocol fact, its source, and verification status
- `TESTING.md` — manual hardware checklist
- `docs/Permissions.md`, `docs/Sandboxing.md`, `docs/Coexistence.md`, `docs/Distribution.md`
- `THIRD_PARTY_NOTICES.md` — attributions and licence decisions

## Licence

MIT. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.

## Trademarks

Tactile is an independent project for DualSense controllers. It is **not affiliated
with, sponsored by, or endorsed by Sony Interactive Entertainment**. "DualSense" and
"PlayStation" are trademarks of Sony Interactive Entertainment Inc. and are used here
only to describe compatibility. No Sony logos are used.
