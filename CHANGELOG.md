# Changelog

Both the Swift API and the C ABI follow [Semantic Versioning](https://semver.org).
Before 1.0.0, minor versions may break the Swift API; the C ABI major
(`TACTILE_ABI_VERSION_MAJOR`) changes on every incompatible C change.

## [Unreleased]

## [0.1.0] — 2026-09-22

### Added
- `TactileCore`: CRC-32, parsers for input reports 0x01 (USB and Bluetooth reduced)
  and 0x31, Edge buttons, IMU calibration (0x05), pairing (0x09), firmware (0x20),
  output builders for 0x31/0x02 and 0x32, the full trigger-effect family, LED
  encodings, firmware feature gating, rate limiter. Golden-byte tests throughout.
- `TactileTransport`: CoreHID discovery and I/O, shared/exclusive modes, rate-limited
  coalescing output, CRC gate, neutral-on-close, crash-recovery journal, Input
  Monitoring helpers, IORegistry conflict detection.
- `TactileHaptics`: resampler, TPDF dither, SPSC ring, mixer with parametric effects
  and rumble emulation, time-constraint pump with metrics, AVAudioEngine tap and
  file sources.
- `TactileBridge`: GameController pairing by uniqueness or input correlation.
- `Tactile`: `ControllerManager` and `Controller` with reconnect handling.
- C ABI 0.1 (`tactile.h`, `libCTactile.dylib`), header check, C++ and Swift samples.
- `tactilectl` and `tactile-probe`.
- Engine bindings: Python (ctypes), Unity (P/Invoke), Godot 4 (GDExtension), Unreal (plugin).

### Not yet verified on hardware
- Everything marked ⚠️/🔬 in `PROTOCOL.md`.
