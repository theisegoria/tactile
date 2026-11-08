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
| DST | daidr/dualsense-tester | MIT | facts only (0x36 layout, audio setup) |
| BRG | matt400/dualsense-bridge (sender, PR #121) | MIT | facts only (0x32/0x36 layout, timing, CBR sizes) |
| DS5D | awalol/DS5Dongle, as cited by KytyPS5 and BRG | MIT | facts only, second-hand (0x39, buffer bytes) |
| LGT | GeorgLegato/LinuxAudio4Dualsense5 (from SundayMoments/DS5_Bridge) | AGPL-3.0 | **facts only**, no code |
| KYT | KytyPS5 PR #148 | GPL-2.0 | **facts only**, no code |
| DRQP | Dr.QP "SAxense feasibility" notes | docs | facts only (describes SAX) |

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
| Status byte 53: bit 0 headphones, bit 1 microphone (SDL also names bit 0 "headphone" and bit 3 "USB") | LNX, SDL | ⚠️ bit 0; 🔬 bit 1 |

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
| Rumble: set haptics-select, plus compat-vibration (fw < 2.21) or compat-vibration-2 (≥ 2.21, Edge) | LNX | ⚠️ (SDL uses compat-vibration-2 from firmware 2.24) |
| Haptics-select (`valid_flag0` bit 1) **disables audio haptics**; a later report with the bit clear restores them. Tactile follows every rumble-off or neutral report sent while the 0x32 stream runs with a report that has the bit clear | SDL | ⚠️ |
| SDL sends byte 1 = `0x00` on every BT 0x31 (no sequence); Linux increments the high nibble. Tactile increments; either is accepted | SDL, LNX | ⚠️ |
| SDL sends 48-byte USB 0x02 reports; Linux and Tactile send 63 | SDL, LNX | ⚠️ |
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

**Cross-check (2026-11-09, Tactile 0.3).** SDL3's `SDL_hidapi_ps5.c` and the
Linux driver implement neither report 0x32 nor 0x36, so they cannot confirm
these layouts. A third-party description of SAxense (Dr.QP "SAxense
feasibility", read for facts only) agrees on: report 0x32, 141 bytes, CRC-32
seeded with `0xA2`, 64 bytes of stereo 8-bit samples per report in a `0x12`
sub-packet, 3000 Hz, ≈ 10.67 ms per report, and a `0x11` packet before it. It
calls the samples unsigned in prose but feeds them signed (`-f s8`) in its
example, so signedness stays open. It does not describe byte 1 or the
sub-packet header bytes. No mismatch with Tactile's defaults was found; every
row below stays 🔬 until gate 3 runs on hardware. `ReportGoldenTests` pins the
bytes Tactile sends.

| Fact | Status |
|---|---|
| **142 bytes** including the report ID (CRC at 138–141), CRC-32 seeded with `0xA2`. SAX descriptions say "141", most likely without the ID. Tactile sizes 0x32 from the controller's descriptor when it declares one (`Controller.hapticsFraming()`) | BRG, DRQP | 🔬 (was 141 before 0.3) |
| Byte 1: 4-bit tag + 4-bit sequence (nibble order unknown; Tactile defaults to seq high, tag `0`) | 🔬 |
| Sub-packet `0x11` (7 bytes, last byte a running counter), then sub-packet `0x12` with 64 bytes of samples | 🔬 |
| Sub-packet header = id \| `0x80` ("sized"), then a length byte: `0x91 07`, `0x92 40` | BRG, LGT, DST | ⚠️ three sources agree |
| `0x11` payload: `FE` (bit 0 clear keeps the mic uplink off) + five buffer bytes + counter. Buffer bytes: BRG `10 10 10 10 10` (reports SAX's `00 00 00 00 FF` stayed silent), DST `40`×5, DS5D `30`×5 during speaker playback, LGT/SAX `00 00 00 00 FF`. Tactile 0.3 defaults to BRG's `10`×5 | BRG, DST, LGT | 🔬 conflict; configurable via `HapticsFraming` |
| 8-bit PCM, 2 channels, 3000 Hz → 32 frames per report → one report every 10.667 ms | 🔬 |
| Samples are signed 8-bit (BRG, DST; the SAX description conflicts with itself) | ⚠️ two sources; `HapticsFraming.signedSamples` (default signed) |
| Any rumble bit (`valid_flag0` bit 0 or 1) in a 0x31 takes the actuators out of audio-haptics mode | BRG, SDL | ⚠️ |
| Channel 0 = left grip actuator, 1 = right | 🔬 |

## Speaker / headphone audio — report `0x36` 🔬

From DST, BRG and LGT (facts only; see Sources). Implemented by
`SpeakerAudioReportBuilder` (`.subPackets`, the default), `SpeakerQueue`,
`Controller.attachSpeaker` and `tactile_speaker_*`. Pinned byte-for-byte by
`ReportGoldenTests`. Nothing confirmed on hardware.

| Fact | Source | Status |
|---|---|---|
| 398 bytes including the report ID; CRC-32 (`0xA2`) little-endian in the last 4 (over bytes 0–393) | DST, BRG, LGT | ⚠️ three sources; Tactile still takes the length from the descriptor |
| Byte 1 = sequence << 4, +1 per report, wraps at 16 | DST, BRG, LGT | ⚠️ |
| Sub-packets with 0x32's header scheme: `0x91 07` control (`FE`, five buffer bytes, counter), `0x92 40` haptics (32 stereo signed 8-bit frames at 3 kHz), `0x93` (speaker) or `0x96` (headphones) + length + one Opus frame | DST, BRG, LGT | ⚠️ |
| Sub-packet order: BRG puts control, haptics, audio (audio at byte 77, Opus at 79); DST and LGT also send a `0x90 3F` packet with a copy of the 0x31 common block, in different orders. Tactile follows BRG (no `0x90`) | DST, BRG, LGT | 🔬 conflict |
| Haptics and audio share every report, so one 10.667 ms stream carries both: Tactile's haptics pump sends 0x36 while audio is queued and 0x32 otherwise | DST, BRG, LGT | 🔬 design |
| One report every 512/48000 s = 10.667 ms (all three say 10 ms drifts or drops out). Each Opus frame encodes 480 samples as 48 kHz, so the audio is resampled to **45 kHz** (DST resamples to 45 kHz; LGT maps 512 samples to 480) | DST, BRG, LGT | ⚠️ |
| Opus: 48 kHz **stereo** CELT, CBR 160 kb/s → fixed **200-byte** frames (LGT: "firmware expects 200 bytes"). BRG instead sends mono hybrid CBR 80 bytes (30–200), citing level dips at CELT frame edges. Tactile uses stereo CELT 200 B: macOS's encoder in CBR mode yields exactly 200-byte frames with TOC `0xF4` (verified in software) | DST, LGT; BRG differs | 🔬 conflict |
| Speaker enable in 0x31: `valid_flag0` `0x20` (speaker volume) \| `0x80` (audio control), audio control `0x30` = speaker only (`0x10` headphones, `0x20` both, `0x00` default); LGT/KYT also set `valid_flag1` `0x80` with common byte 37 = `0x02` (+6 dB preamp), not implemented | LGT, KYT, DST | 🔬 |
| Speaker volume: maximum `0x64` (DST, KYT, LGT); LGT's older script: only `0x3D`–`0x64` work; BRG: 0–255. Headphone maximum `0x7F` | DST, KYT, LGT, BRG | 🔬 conflict |
| `0x91` mask bit 0 set (`FF`) makes the pad send microphone Opus back in input 0x31 (marker `0xD4`, 48 kHz mono, 10 ms) | LGT | 🔬 |
| Report `0x39` (547 bytes, 21.333 ms): two haptics blocks and two 200-byte Opus frames per report | KYT (from DS5D) | 🔬 not implemented |
| No feature report is needed to enable audio | BRG | 🔬 |

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
| Speaker/headphone audio in output report `0x36` as Opus: see "Speaker / headphone audio — report 0x36" above | OPUS, DST, BRG, LGT | 🔬 | `SpeakerAudioReportBuilder`, `SpeakerQueue`, `SpeakerStream` |
| The pre-0.3 guessed layout (sequence byte, length prefix, Opus) is kept as `SpeakerAudioFraming.Layout.lengthPrefixed` for research; no source describes it. SDL and Linux implement no audio report | none | 🔬 superseded | |
| USB audio function: 4 output channels, 1–2 speaker/headset, 3–4 left/right actuators; product strings "DualSense Wireless Controller" / "DualSense Edge Wireless Controller" | community reports; SDL (Edge name) | 🔬 | `TACTILE_USB_AUDIO_*` |
| `0x36` length: taken from the controller's own report descriptor at runtime | — | parser tested | `HIDDescriptor` |
| Microphone uplink as Opus at 24 kHz; report ID and layout unknown | OPUS | 🔬 found at runtime by `UplinkScanner` | `mic-scan` |
| macOS's built-in Opus encoder produces TOC `0xF4` (CELT FB 10 ms stereo) for 48 kHz stereo — the exact format of the lead | this project, AudioToolbox | ✅ verified in software (not on device) | `OpusCodecTests` |
| Edge profiles / stick modules: which feature reports change | — | unknown; read-only snapshot + diff tooling | `features`, `features-diff` |

Safety rules for the experimental code: no feature report is ever **written**;
the raw output path refuses report IDs that have validated paths (0x31, 0x02,
0x32), requires a valid CRC over Bluetooth, and is capped at 250 reports/s.
Neutral state does not touch audio settings (their power-on defaults are unknown).
