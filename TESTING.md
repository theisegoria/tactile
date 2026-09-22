# Hardware test checklist

Automated tests (`swift test`, `scripts/check-c-abi.sh`) cover everything that can
run without a controller. This checklist covers the rest. **Every acceptance test
runs over Bluetooth.** Record results (and paste logs) in `docs/receipts/`.

## Setup

1. Pair the controller: hold PS + Create until the lightbar flashes, then System
   Settings › Bluetooth.
2. Grant **Input Monitoring** to your terminal (or the sample app):
   `swift run tactilectl permission`, then System Settings › Privacy & Security ›
   Input Monitoring. Restart the terminal afterwards.
3. Quit Steam and any other controller utilities for the baseline run.

## Gate 0 — reconnaissance (`tactile-probe`)

| # | Step | Expect | Confirms |
|---|---|---|---|
| 0.1 | `swift run tactile-probe list` | device listed, transport bluetooth, descriptor dumped | discovery, descriptor |
| 0.2 | same, Edge (if available) | PID 0x0DF2; note descriptor differences | Edge identification |
| 0.3 | `swift run tactile-probe reports 3` | phase 1 only `0x01` (10 bytes), phase 2 `0x31` (78 bytes); note `data[0]==id` count | 0x01→0x31 switch; report-ID convention |
| 0.4 | `swift run tactile-probe features` | 0x05 41(+4) bytes, 0x09 20(+4), 0x20 64(+4); `crcA3=true` | feature lengths, 0xA3 CRC |
| 0.5 | revoke Input Monitoring, rerun 0.1 and 0.3 | list works? open fails with which error? | permission behaviour (record exact error) |
| 0.6 | `swift run tactile-probe gc 8` | note: light magenta? triggers stiff? read-back modes; Core Haptics buzz | GameController support matrix (background) |
| 0.7 | run the TactileDemo app frontmost, repeat 0.6 via GameController-only buttons (future) | frontmost vs background | frontmost matrix |
| 0.8 | start Steam, `swift run tactile-probe conflicts` | Steam listed; virtual twins > 0? | coexistence detection |
| 0.9 | with Steam running: `tactilectl light '#ff0000' --hold 10`; does the colour revert? | revert = Steam overwrites | last-writer-wins |

## Gate 2 — basic output (`tactilectl`)

| # | Step | Expect |
|---|---|---|
| 2.1 | `tactilectl info` | model, bluetooth, MAC equals serial, firmware + update version, battery, `input IDs: [0x31]` |
| 2.2 | `tactilectl monitor --imu --touch` | sticks/buttons/triggers correct; gyro ≈ 0 at rest; accel ≈ 1 g on the gravity axis; touch coordinates 0–1919 × 0–1079 |
| 2.3 | Edge: press Fn1, Fn2, left/right paddle in `monitor` | shows Fn1, Fn2, PaddleL, PaddleR in that order (**confirms bit order**) |
| 2.4 | `tactilectl light '#00ff00'` | lightbar green, restored on exit |
| 2.5 | `tactilectl leds 1` … `leds 5`, `leds 3 --mute pulse --brightness low` | patterns centre-out; mute LED pulses; brightness changes (**confirms byte 42 without a flag**) |
| 2.6 | `tactilectl trigger right feedback 2 8`, `weapon 3 6 8`, `vibration 2 8 30`, `slope 0 9 1 8` | each feels right; released on exit |
| 2.7 | unofficial: `trigger right bow 1 6 6 8`, `galloping 0 9 4 7 5`, `machine 2 9 3 7 8 4` | each works |
| 2.8 | `tactilectl rumble 255 0 1`, `rumble 0 255 1` | heavy vs light motor; test on fw < 2.21 and ≥ 2.21 if possible |
| 2.9 | `tactilectl --exclusive monitor` while a GameController app runs | the other app stops seeing the pad |
| 2.10 | Ctrl-C during `trigger … --hold 30` | trigger released, lightbar restored |
| 2.11 | `kill -9` during a trigger hold, then `tactilectl info` | crash-recovery journal neutralises on next open |
| 2.12 | switch the controller off/on during `monitor` in the Swift sample | `reconnected` event, owned state re-applied |

## Gate 3 — Bluetooth haptics

| # | Step | Expect / record |
|---|---|---|
| 3.1 | `tactilectl haptic --effect click --repeat 10` | crisp clicks; if nothing, try `HapticsFraming` variants (nibble order, signed/unsigned, headers) and record which works |
| 3.2 | `--side left`, `--side right` | confirms channel 0 = left |
| 3.3 | `tactilectl haptic music.wav` | audible-rate haptics follow the audio; print metrics |
| 3.4 | `tactilectl haptic --mic` | speech drives haptics |
| 3.5 | during 3.3 run `tactilectl rumble 200 200 2` in parallel | does 0x31 rumble interrupt 0x32 audio? (arbitration) |
| 3.6 | record metrics: wake lateness p99, tick σ, send latency mean/p99, underruns, CPU | fill `docs/receipts/gate-3.md` |
| 3.7 | end-to-end latency: tap the mic and film controller + mic at 240 fps | frames between tap and buzz |

## Gate 4 — C ABI

| # | Step | Expect |
|---|---|---|
| 4.1 | `Samples/CppGameLoop/build.sh` then run it | Cross clicks, Circle toggles weapon on R2, left stick drives lightbar |
| 4.2 | `Samples/SwiftSample/bundle.sh && open …/TactileDemo.app` | UI shows live input; buttons work |
| 4.3 | `./bundle.sh app-store` build, run sandboxed | still opens the controller (**confirms sandbox entitlements**) |
