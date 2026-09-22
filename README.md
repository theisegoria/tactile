# Tactile

**Full-feature Bluetooth support for DualSense and DualSense Edge controllers on macOS.**

Tactile is a Swift package (with a C ABI) that gives macOS apps and game engines the
parts of the DualSense feature set that Apple's GameController framework does not
expose: HD audio-haptics over Bluetooth, every adaptive-trigger effect, lightbar,
player and mute LEDs, calibrated IMU, and the Edge's paddles and Fn buttons.

It works *alongside* GameController: GameController keeps doing discovery and
standard input; Tactile talks to the controller's HID protocol directly for the rest.

> Status: pre-1.0, under active development. See `docs/receipts/` for gate reports
> and `PROTOCOL.md` for which facts have been verified on hardware.

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
| `Tactile` | High-level `Controller` facade. |
| `CTactile` | C ABI (`include/tactile.h`) for engines and non-Swift hosts. |
| `tactilectl` | CLI demo and hardware test harness. |

## Quick start

```swift
import Tactile

let manager = ControllerManager()
for await controller in manager.controllers() {
    try await controller.setLightbar(.init(red: 255, green: 0, blue: 128))
    try await controller.setTrigger(.right, .weapon(start: 3, end: 6, strength: 8))
}
```

```bash
swift run tactilectl list
swift run tactilectl trigger right weapon 3 6 8
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
