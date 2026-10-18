# Tactile Lab

A native SwiftUI workspace for exploring DualSense and DualSense Edge over Bluetooth. Requires Apple silicon and macOS 27. The underlying Tactile package still supports macOS 15 and both Mac architectures.

## Build and run

Open `TactileLab.xcodeproj` in Xcode 27.1, or run `./scripts/run-lab.sh` from the repository root. The Codex Run action invokes the same script. It preserves an already-running app: quit that app yourself to load a newly compiled version.

`./scripts/run-lab.sh --build-only` builds without opening a window. `./scripts/run-lab.sh --simulate` opens the visibly labeled simulation when no app is already running. Simulator scenarios can be selected with `--scenario connected`, `denied`, `no-device`, `multiple`, `stale`, or `failure`. Simulation sends no controller output and establishes no physical acceptance.

The checked-in project is generated from `project.yml` with XcodeGen 2.44.1. Run `xcodegen generate` after changing targets or adding files. The post-generation script sets the Icon Composer file type because this XcodeGen version does not recognize `.icon` automatically. App, unit-test and UI-test schemes are shared. `UITesting` uses a distinct bundle identifier so test teardown does not terminate the normal app.

```sh
xcodebuild -project TactileLab.xcodeproj -scheme TactileLabTests \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project TactileLab.xcodeproj -scheme TactileLabUITests \
  -destination 'platform=macOS,arch=arm64' test
```

## Usage

Pair a controller in Bluetooth settings, allow Input Monitoring, and select it. The app filters Bluetooth devices before opening them. Shared access is the default; applying Exclusive access performs an orderly reconnect. Connecting and reconnecting leave outputs neutral.

- **Input:** generated front/rear visual reference, live button/stick/trigger/touch overlays, named controls, calibrated motion, battery and report rate.
- **Effects:** lightbar, player/mute LEDs, rumble, adaptive trigger presets and validated custom parameters, parametric haptics, audio-file haptics and host-microphone haptics.
- **Audio:** experimental routing, speaker playback, framing controls, microphone candidate scans and WAV recording.
- **Diagnostics:** firmware, report descriptor sizes, conflicts, GameController correlation, haptics metrics, filtered raw reports and read-only feature snapshots/comparisons.
- **Tests:** explicit output checks and human Pass/Fail/Skipped/Unverified observations, with local versioned JSON and Markdown export.

Command-1 through Command-5 switch tabs. Command-period stops app-owned effects. Command-Shift-R retries the connection, Command-Shift-E exports a report, and Command-0 opens the main window.

Output tests default to three seconds and accept 0.1–60 seconds. Stop All, device changes, disconnect and quit cancel pending operations before requesting neutral outputs. Quit has an independent three-second completion deadline. Raw history, snapshots and receipt history are bounded; visual input updates are limited to approximately 30 Hz. Audio conversion, raw parsing and diagnostics collection run away from the main actor.

## Artwork

Original Image Gen sources and exact prompts are retained in `Artwork/`. The controller references are transparent raster artwork in the asset catalog, with SwiftUI live overlays aligned to normalized landmarks. They are generated visual references, not Sony photographs, CAD models or proof of hardware behavior.

`TactileLab/TactileLab.icon` is the Icon Composer source. The icon uses an ivory controller, graphite background and small cyan accents; Dark/Mono appearances are handled by Icon Composer. Xcode compiles the layered icon into the app's asset catalog and Finder icon.

## Local release

`./scripts/release-lab.sh --archive-only` creates and verifies a Developer ID archive under `build/`. It checks the bundle identifier, minimum OS, arm64 binary, hardened runtime and audio-input entitlement.

Run `scripts/configure-notarization.command` in Terminal to configure the `tactile` Keychain profile. Enter credentials only into the local notarytool prompts; never put them in source or chat. After setup, run `./scripts/release-lab.sh --from-archive '/absolute/path/to/Tactile Lab.xcarchive'` or run the script without arguments to rebuild. It submits to Apple, checks Accepted results, staples and validates the app and DMG, performs Gatekeeper assessments, and only then populates `dist/TactileLab` with ZIP, DMG, checksums, installation notes and verification records. No public upload is performed.

Hardware acceptance is deferred at the owner's request. A software pass, decoded packet or successful HID transmission never automatically establishes a felt or heard response. See the current receipt and hardware checklist in `docs/receipts/`.
