# Gate 0 receipt — reconnaissance

Date: 2026-09-22 · macOS 27.0 (26A428) · Xcode 27.0 · Swift 6.4 · Apple silicon

## What was built

`tactile-probe` (`Sources/tactile-probe/`), talking to CoreHID directly:

| Command | Answers |
|---|---|
| `list` | enumerates DualSense/Edge incl. virtual devices; dumps report descriptor and declared report IDs |
| `reports [s]` | counts raw input reports by ID before and after GET_FEATURE 0x05 (the 0x01→0x31 switch); records whether CoreHID's `data` includes the report-ID byte |
| `features` | raw 0x03/0x05/0x09/0x20, with the 0xA3 CRC check |
| `gc [s]` | GameController: battery, light, haptics localities, motion, physical-input elements; sets light + trigger modes and reads them back; plays a Core Haptics event |
| `conflicts` | other processes with an IOHIDLibUserClient on the pad; virtual twins (Steam) |
| `request-permission` | triggers the Input Monitoring prompt |

## What was run, and what happened

```
$ swift run tactile-probe list
[03:06:04.211] tactile-probe list — macOS Version 27.0 (Build 26A428)
[03:06:04.220] Input Monitoring: denied
[03:06:04.627] Found 0 device(s)
```

- The Mac has a DualSense **paired** (`system_profiler`: address redacted,
  VID 0x054C, PID 0x0CE6) but it was **not connected** during this session (no
  IOHIDDevice with PID 0x0CE6 in the IORegistry).
- The process running the build has Input Monitoring **denied**.

**So no hardware finding exists yet.** Every row below is the expectation from
public sources, to be filled in by running TESTING.md §Gate 0.

## Support matrix (expected → to verify)

| Feature | GameController (frontmost) | GameController (background) | Tactile (HID) |
|---|---|---|---|
| Buttons, sticks, triggers | ✅ expected | ⚠️ needs `shouldMonitorBackgroundEvents` (regressed 15.4, fixed 15.5) | ⏳ |
| Edge paddles / Fn | ❌ no API | ❌ | ⏳ (bits 4–7 of buttons byte 2) |
| Touchpad | ✅ | ⚠️ | ⏳ |
| IMU | ✅ `GCMotion` | ⚠️ | ⏳ (calibrated from 0x05) |
| Battery | ✅ | ✅ | ⏳ |
| Lightbar | ⚠️ reported ignored on macOS 26 | ⚠️ | ⏳ |
| Player LEDs, mute LED | ❌ no API | ❌ | ⏳ |
| Adaptive triggers | ⚠️ `setMode` reported to read back `.off` (FB thread 771756) | ⚠️ | ⏳ |
| Rumble | ✅ Core Haptics (rumble-class) | ⚠️ | ⏳ (0x31) |
| Audio-waveform haptics | ❌ | ❌ | ⏳ (0x32, 🔬) |
| Speaker / mic | ❌ | ❌ | research (gate 6) |

## Coexistence findings

Not measured yet. Built so they can be: `tactile-probe conflicts` and
`tactilectl conflicts` list other HID clients by process; TESTING.md 0.8–0.9 test
whether Steam or GameController overwrite output.

## Design consequences (already applied)

1. **Shared mode touches only owned fields** (valid flags clear for everything the
   app never set), so Tactile does not undo GameController/Steam state by accident.
2. **Exclusive mode** exists for when a writer keeps winning; it forfeits
   GameController, so Tactile supplies full input itself.
3. **No trust in the report-ID convention**: input and feature buffers are
   normalised whether or not CoreHID includes the ID byte; the probe records which.
4. **GameController has no public identifier** (confirmed in the macOS 27 SDK), so
   the bridge cannot pair by MAC on the GameController side; it uses uniqueness or
   input correlation (never connection order).
5. **Permission is detected up front** (`IOHIDCheckAccess`) and failures map to a
   dedicated error, since a missing Input Monitoring grant is the most likely
   first-run failure.

## Assumptions for the maintainer to check

- CoreHID needs Input Monitoring just like IOKit/hidapi (TESTING 0.5), and which
  error it returns.
- Reading 0x05 via CoreHID triggers the 0x31 switch (TESTING 0.3).
- `IOUserClientCreator` on the device's children is a reliable "who has it open"
  signal on macOS 27.

## Failures

None in code. Hardware steps could not run (see above).

## PROTOCOL.md changes

Created. All facts marked ⚠️/🔬; none verified on device.
