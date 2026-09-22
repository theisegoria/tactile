# Architecture

```
            ┌─────────── host app / engine ───────────┐
            │  Swift: import Tactile     C/C++: tactile.h (libCTactile)
            └──────────────┬──────────────────┬───────┘
                           ▼                  ▼
                        Tactile  ◄──────  TactileCABI
          (ControllerManager, Controller)
             │           │            │
             ▼           ▼            ▼
   TactileTransport  TactileHaptics  TactileBridge ──► GameController
   (CoreHID, IOKit)  (AVFAudio)
             └───────────┼────────────┘
                         ▼
                    TactileCore  (pure Swift, no I/O, no dependencies)
```

- GameController keeps doing discovery and standard input for apps that want it;
  Tactile opens the same HID device in **shared** mode for everything else.
- `TactileCore` has no platform imports, so every encoder/decoder is unit-tested
  with golden bytes.
- `DeviceConnection` is an actor per device. It owns the output state the app has
  set, coalesces updates under a rate limit (default 125 reports/s) and refuses to
  send any Bluetooth report whose CRC does not verify.
- Neutral state (triggers off, rumble off, lightbar restored) is written on close,
  on Ctrl-C in `tactilectl`, and on the next open after a crash (journal in
  `~/Library/Caches/Tactile/dirty/`).

## Pairing HID devices with GCControllers

HID identity is the controller's MAC (feature report 0x09, cross-checked with the
HID serial number). GameController exposes no public identifier, so
`ControllerBridge` matches a `GCController` to a HID device when there is exactly
one of each, or by correlating button edges seen through both APIs within 35 ms
(three coincidences and a clear winner required). Connection order is never used.

## Virtual device seam

A system-wide virtual controller (so unmodified games see Edge paddles etc.) would
need `HIDVirtualDevice` and the restricted `com.apple.developer.hid.virtual.device`
entitlement. It is out of scope. The seam: `DeviceConnection.inputEvents()` already
yields decoded state plus the raw report; a future `VirtualPadPublisher` would
consume that stream and call `HIDVirtualDevice.dispatchInputReport`. Nothing is built.
