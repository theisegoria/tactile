# DualSense protocol reference (as used by Tactile)

Every fact the code depends on, with its source and verification status.

**Status legend**
- ✅ **verified on device**: confirmed with `tactile-probe`/`tactilectl` on real hardware (log in `docs/receipts/`).
- ⚠️ **unverified**: from public sources only. The code implements it, and `TESTING.md` has a step that confirms it.
- 🔬 **single source / reverse engineered**: treat with extra suspicion.

As of 2026-09-22 **no fact has been verified on device yet**. The development
machine had a paired DualSense (address omitted from the public repository) but it was not connected, and the build process did not have
Input Monitoring. See `docs/receipts/gate-0.md`.

**Sources** (see `THIRD_PARTY_NOTICES.md` for licences and how each was used)

| Key | Source | Licence | Use |
|---|---|---|---|
| SDL | SDL3 `src/joystick/hidapi/SDL_hidapi_ps5.c` | zlib | facts; layout names |
| LNX | Linux `drivers/hid/hid-playstation.c` | GPL-2.0+ | **facts only**, no code |
| DSCTL | dualsensectl | GPL-2.0 | **facts only** |
| NLK | Nielk1, "TriggerEffectGenerator" gist | MIT | adapted (trigger encoders), attributed |
| SAX | SAxense | MPL-2.0 | **facts only; clean-room** implementation |
| NDB | nondebug/dualsense | none | facts only |
| OPUS | unlicensed Opus-audio repository (lead) | none | facts only, research lead |
| APPLE | macOS 27 SDK headers (GameController, CoreHID) | — | API facts |

## Identification

| Fact | Source | Status |
|---|---|---|
| Sony VID `0x054C`; DualSense PID `0x0CE6`; DualSense Edge PID `0x0DF2` | SDL, LNX | ⚠️ (PID `0x0CE6` matches this Mac's pairing record) |
| The Edge's Bluetooth descriptor can differ (trailing `0x00`, 4 axes not 6, different vendor report IDs) and has been misidentified as a plain DualSense → identify by PID and feature reports, never by descriptor | prompt / community reports | 🔬 |
| macOS reports the controller's MAC as the HID `SerialNumber` for Bluetooth devices (`02-11-22-33-44-55` form) | general macOS behaviour | ⚠️ |

## CRC

| Fact | Source | Status |
|---|---|---|
| CRC-32, reflected poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR (zlib CRC) | SDL, LNX | ⚠️ |
| Computed over a one-byte prefix + the report bytes, stored little-endian in the last 4 bytes | SDL, LNX | ⚠️ |
| Prefix `0xA1` input, `0xA2` output, `0xA3` feature (Bluetooth GET_REPORT replies) | SDL, LNX | ⚠️ (`0xA3` is the least certain) |

## Input

| Fact | Source | Status |
|---|---|---|
| Bluetooth starts in reduced report `0x01` (10 bytes: LX LY RX RY, 3 button bytes, L2, R2) | SDL, LNX | ⚠️ |
| In `0x01`-BT, button byte 3's top 6 bits are a counter (only PS/touchpad bits are buttons) | SDL | ⚠️ |
| Reading feature `0x05` switches Bluetooth input to full report `0x31` (78 bytes, CRC) | SDL, LNX | ⚠️ — `tactile-probe reports` checks this |
| `0x31`: byte 1 = sequence/tag; 63-byte common block from byte 2; CRC at 74–77 | SDL, LNX | ⚠️ |
| USB input `0x01` (64 bytes) = same common block from byte 1 | SDL, LNX | ⚠️ |
| Common block offsets: sticks 0–3, L2 4, R2 5, seq 6, buttons 7–9, gyro 15–20 (int16 ×3), accel 21–26, sensor timestamp 27–30, touch 32–39, status 52 | LNX, SDL | ⚠️ |
| Buttons byte 0: hat low nibble (0=N … 7=NW, 8=released), □ ✕ ○ △ bits 4–7; byte 1: L1 R1 L2 R2 Create Options L3 R3; byte 2: PS, touchpad, mute | LNX, SDL | ⚠️ |
| Edge: Fn1, Fn2, left paddle, right paddle = bits 4–7 of buttons byte 2 (Linux driver, May 2026) | LNX | 🔬 order unverified |
| Touch point: byte 0 bit 7 = *not* touching, bits 0–6 id; 12-bit X, 12-bit Y packed in 3 bytes; 1920×1080 | LNX, SDL | ⚠️ |
| Status byte: low nibble battery 0–10, high nibble 0 discharging / 1 charging / 2 full / A,B,F error; percent = min(level×10+5, 100) when discharging/charging, 100 when full, 0 for error (A, B, F) and unknown states | LNX | ⚠️ |
| Status byte 53: bit 0 headphones, bit 1 microphone | LNX | 🔬 |

## Feature reports

| ID | Length | Fact | Source | Status |
|---|---|---|---|---|
| `0x03` | — | capabilities (dumped raw by the probe, not parsed) | prompt | 🔬 |
| `0x05` | 41 | calibration: int16 gyro bias p/y/r; gyro plus/minus pairs p, y, r; gyro speed plus/minus; accel plus/minus pairs x, y, z | LNX, SDL | ⚠️ |
| `0x05` | | gyro deg/s = raw × (speed⁺ + speed⁻) / (\|plus − bias\| + \|minus − bias\|) — the bias feeds only the denominator because the firmware already bias-corrects the samples (LNX sets the gyro bias to 0; SDL subtracts it — the references disagree, unverified on hardware; the parsed bias is exposed as `IMUCalibration.factoryGyroBias`, and apps should prefer an at-rest drift recalibration); accel g = (raw − (plus − range/2)) × 2 / range, range = plus − minus | LNX | ⚠️ |
| `0x09` | 20 | bytes 1–6 = controller MAC, least-significant first | LNX, SDL | ⚠️ |
| `0x20` | 64 | ASCII build date 1–11, time 12–19; hardware version u32 @24; firmware version u32 @28; **update version u16 @44** | LNX | ⚠️ |

**Changed from the prompt:** the prompt says vibration v2 needs "firmware 2.21".
The Linux driver compares the **update version** (u16 at offset 44, `major<<8|minor`)
against 2.21, not the firmware version at offset 28. Tactile follows the driver
(`FeatureSet.vibrationV2MinimumUpdateVersion = 0x0215`). The Edge always uses v2.

## Output report `0x31` (Bluetooth) / `0x02` (USB)

| Fact | Source | Status |
|---|---|---|
| BT: `0x31`, byte 1 = seq << 4 (4-bit counter), byte 2 = tag `0x10`, common block (47 bytes) from byte 3, CRC at 74–77, total 78 | LNX, SDL | ⚠️ |
| USB: `0x02`, common block from byte 1, 63 bytes | LNX | ⚠️ |
| Common block: `valid_flag0` 0, `valid_flag1` 1, motor right 2, motor left 3, audio 4–7, mute LED 8, power-save 9, right trigger 10–20, left trigger 21–31, `valid_flag2` 38, lightbar setup 41, LED brightness 42, player LEDs 43, RGB 44–46 | LNX, SDL | ⚠️ |
| `valid_flag0`: bit0 compatible vibration, bit1 haptics select, bit2 right trigger, bit3 left trigger | LNX | ⚠️ |
| `valid_flag1`: bit0 mute LED, bit1 power save (mic mute), bit2 lightbar, bit3 release LEDs, bit4 player indicator | LNX | ⚠️ |
| `valid_flag2`: bit1 lightbar setup, bit2 compatible vibration 2 | LNX | ⚠️ |
| Rumble: set haptics-select, plus compat-vibration (fw < 2.21) or compat-vibration-2 (≥ 2.21, Edge) | LNX | ⚠️ |
| Lightbar colours only apply after the firmware's own animation is released: lightbar setup byte = `0x02` with `valid_flag2` bit 1 | LNX | ⚠️ |
| Player LED patterns 1–5: `0x04 0x0A 0x15 0x1B 0x1F`; bit 5 = switch instantly | LNX | ⚠️ |
| Mute LED: 0 off, 1 on, 2 pulse; mic mute = power-save bit 4 | LNX | ⚠️ |
| LED brightness (byte 42: 0 high, 1 medium, 2 low) has **no known valid flag**; Tactile writes it alongside the player-indicator flag | SDL | 🔬 |
| Each report carries full state for every flagged field → last writer wins | prompt, LNX | ⚠️ |

## Trigger effects (11 bytes per trigger)

All from NLK. Official: Off `0x05`, Feedback `0x21`, Weapon `0x25`, Vibration `0x26`.
Unofficial: Bow `0x22`, Galloping `0x23`, Machine `0x27`. Multi-position feedback
and vibration reuse `0x21`/`0x26` with per-zone 3-bit values; Slope Feedback is built
on multi-position feedback with **half-to-even rounding** (C# `Math.Round`). Status ⚠️
for all; unofficial effects 🔬. Byte layouts are in `TriggerEffect.swift` and pinned
by `TriggerEffectTests`. The "Simple_*" and "Limited_*" effect families in the gist
are not implemented.

## Bluetooth audio haptics — report `0x32` (clean-room from SAX facts) 🔬

| Fact | Status |
|---|---|
| 141 bytes, CRC-32 seeded with `0xA2` | 🔬 |
| Byte 1: 4-bit tag + 4-bit sequence (nibble order unknown; Tactile defaults to seq high, tag `0`) | 🔬 |
| Sub-packet `0x11` (7 bytes, last byte a running counter), then sub-packet `0x12` with 64 bytes of samples | 🔬 |
| Sub-packet header encoding (`0x91`/`0x92`: id + "sized" bit 7, then a length byte) and the `0x11` payload (`FE 00 00 00 00 FF`) | 🔬 guessed; configurable via `HapticsFraming` |
| 8-bit PCM, 2 channels, 3000 Hz → 32 frames per report → one report every 10.667 ms | 🔬 |
| Signed vs unsigned samples | unknown; `HapticsFraming.signedSamples` (default signed) |
| Channel 0 = left grip actuator, 1 = right | 🔬 |

## GameController facts (APPLE)

| Fact | Status |
|---|---|
| `GCDualSenseGamepad`, `GCDualSenseAdaptiveTrigger` (modes Off/Feedback/Weapon/Vibration/SlopeFeedback + positional variants; read-back `mode`, `status`, `armPosition`) | SDK headers ✅ |
| `GCDeviceLight`, `GCDeviceBattery`, `GCController.haptics` (Core Haptics, localities incl. handles/triggers) | SDK headers ✅ |
| No public API for player LEDs, mute LED, speaker/mic audio or audio-driven haptics | SDK headers ✅ |
| **No public MAC address, HID service or other hardware identifier on `GCController`** | SDK headers ✅ (grep of macOS 27 SDK) |
| Reported: `setMode` ignored (reads back `.off`), macOS 26 ignoring lightbar/triggers, `shouldMonitorBackgroundEvents` regressed in 15.4 | ⚠️ `tactile-probe gc` tests these |

## Transport facts (CoreHID, APPLE)

| Fact | Status |
|---|---|
| `HIDDeviceManager.monitorNotifications(matchingCriteria:)`; `HIDDeviceClient.dispatchSetReportRequest/dispatchGetReportRequest(type:id:data:timeout:)`, `monitorNotifications(reportIDsToMonitor:elementsToMonitor:)`, `transport`, `seizeDevice()` | SDK ✅ |
| Whether CoreHID input/feature buffers include the report-ID byte | ⚠️ normalised both ways; the probe reports it |
| Opening a gamepad needs Input Monitoring; without it opens fail (`kIOReturnNotPermitted` in IOKit; `HIDDeviceError.notPermitted` expected in CoreHID) | ⚠️ |

## Gate 6 — experimental (implemented, nothing verified) 🔬

Everything below is implemented behind clearly marked experimental APIs
(`AudioSettings`, `TactileAudio`, `Controller+Experimental`, `tactilectl` commands
listed under "experimental") so it can be tested the moment hardware is available.

| Fact | Source | Status | Where |
|---|---|---|---|
| Common-block bytes 4–7 = headphone volume, speaker volume, mic volume, audio control; enabled by `valid_flag0` bits 4–7 | LNX (audio-jack work) | 🔬 | `AudioSettings` |
| Audio control bits 4–5 select the output path (0 headphones … 3 speaker); intermediate values | LNX | 🔬 | `AudioOutputPath` |
| Volume ranges: headphone ≤ 0x7F, mic ≤ 0x40 (clamped), speaker 0–0xFF | LNX | 🔬 | `AudioSettings.encode` |
| Speaker/headphone audio in output report `0x36` as Opus, CELT, 48 kHz stereo, 10 ms per report | OPUS | 🔬 | `SpeakerAudioReportBuilder`, `SpeakerStream` |
| `0x36` layout: byte 1 seq/tag, then a length prefix and the Opus packet, CRC-32 (0xA2) — **guessed** | none (by analogy with 0x31/0x32) | 🔬 configurable (`SpeakerAudioFraming`) | |
| `0x36` length: taken from the controller's own report descriptor at runtime | — | parser tested | `HIDDescriptor` |
| Microphone uplink as Opus at 24 kHz; report ID and layout unknown | OPUS | 🔬 found at runtime by `UplinkScanner` | `mic-scan` |
| macOS's built-in Opus encoder produces TOC `0xF4` (CELT FB 10 ms stereo) for 48 kHz stereo — the exact format of the lead | this project, AudioToolbox | ✅ verified in software (not on device) | `OpusCodecTests` |
| Edge profiles / stick modules: which feature reports change | — | unknown; read-only snapshot + diff tooling | `features`, `features-diff` |

Safety rules for the experimental code: no feature report is ever **written**;
the raw output path refuses report IDs that have validated paths (0x31, 0x02,
0x32), requires a valid CRC over Bluetooth, and is capped at 250 reports/s.
Neutral state does not touch audio settings (their power-on defaults are unknown).
