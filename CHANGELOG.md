# Changelog

Both the Swift API and the C ABI follow [Semantic Versioning](https://semver.org).
Before 1.0.0, minor versions may break the Swift API; the C ABI major
(`TACTILE_ABI_VERSION_MAJOR`) changes on every incompatible C change.

## [Unreleased]

Targets 0.4.0 (`TactileVersion` is 0.4.0). Nothing below has been checked on a
controller yet: the feel of trigger presets, live pattern playback, profiles and
system-audio haptics are UNVERIFIED on hardware; the tests are hardware-free.

### Added — Swift
- Trigger effects: `TriggerEffectSpec` (the factory call behind an effect, Codable
  with a `type` field, decodable from wire bytes), `TriggerCurve` / `.curve`
  (resistance, vibration amplitude and frequency over trigger travel 0…1, with
  time-resolved envelopes for machine and galloping) and `TriggerPreset` (off,
  weapon trigger, bow draw, brake pedal, click/detent, machine gun, gallop).
  `TriggerSide` moved to TactileCore (still re-exported by `Tactile`) and is Codable.
- Haptic patterns: `HapticPattern` (`.tactilepattern` JSON, schema version 1) with
  tracks of parametric effects, audio clips (path, gain, trim, side), rumble,
  trigger changes and lightbar keys (step or linear).
  `HapticPatternRenderer.renderOffline` renders per-actuator PCM at 3 kHz without
  a device, deterministically (`HapticPreview`: floats, 8-bit samples, waveform
  peaks). `HapticPatternPlayer` streams that render into the mixer and sends
  trigger/lightbar changes on a clock; `Controller.startPattern` / `play(_:)`.
- System audio to haptics: new `TactileSystemAudio` product with
  `SystemAudioHapticsSource` (ScreenCaptureKit audio-only capture of all system
  audio except this process, or one app). Needs the Screen Recording permission
  (`hasPermission`, `requestPermission()`). `HapticFilterChain` /
  `HapticFilterSettings` (low-pass or band-pass, gain, compressor, gate; presets
  passthrough, music, game) and `HapticAudioPipeline` in TactileHaptics.
- Input analysis: `InputRecording` (Codable, record/replay,
  `Controller.recordInput`) and `InputAnalysis` (stick drift and recommended dead
  zone, circularity, trigger travel, button timing, report interval statistics,
  sequence gaps), `IntervalStatistics`.
- Profiles: `ControllerProfile` (lightbar, player LEDs, triggers, haptic gain,
  preferred pattern), `Controller.apply(_:)`, `ProfileStore` (JSON files in
  Application Support, injectable directory).
- `TactileCodeExport` / `CodeLanguage`: snippets for trigger effects, presets,
  patterns and profiles in Swift, C, Unity C#, Unreal C++ and Godot GDScript.
- USB: connection-level golden tests for the existing USB path (0x01 in, 0x02
  out). Whether USB needs the Bluetooth lightbar-release step is unverified.

### Added — C ABI 0.4 (additive; 0.3 callers keep working)
- `tactile_trigger_from_preset` with `tactile_trigger_preset` values.
- `tactile_pattern_load_file/load_json/free/duration/render`,
  `tactile_pattern_play/stop/is_playing` (non-blocking, one pattern per controller).
- `tactile_profile_apply_file/json`.
- Bindings: Python (tested), Unity, Unreal and Godot (not compiled here).

## [0.3.0] — 2026-11-09 (release candidate)

### Added — C ABI 0.3 (additive; 0.2 callers keep working)
- Speaker: `tactile_speaker_open/close/write_pcm/write_opus/set_destination/flush/get_stats`.
  Report 0x36 now follows public implementations (daidr/dualsense-tester and
  dualsense-bridge, both MIT; facts only). It is 398 bytes with control, haptics and
  speaker/headphone sub-packets, and goes out every 10.667 ms. The haptics pump sends it
  in place of 0x32 while audio is queued, so haptics and speaker share one stream on the
  controller's own connection. PCM at any rate is resampled to 45 kHz and encoded as
  CBR 160 kb/s stereo CELT, giving 200-byte frames. Bounded queue, silence on underrun,
  and the stream ends after the idle time.
  Swift: `SpeakerQueue`, `Controller.attachSpeaker`, `SpeakerPacketSource`. The pre-0.3
  guessed layout remains as `SpeakerAudioFraming.Layout.lengthPrefixed`.
- `tactile_controller_set_audio`: headphone/speaker/mic volume and output path, over
  Bluetooth (0x31) and USB (0x02).
- `tactile_controller_info`: `vendor_id`, `product_id`, HID `product` string,
  `capabilities` (`TACTILE_CAP_*`) and `capabilities_unverified`.
- `tactile_input_state`: `headphones` and `microphone` (status byte 53), `host_time_ns`.
- `tactile_haptics_metrics`: `buffered_ms`, `report_period_us`, `estimated_latency_ms`,
  `running`, `sending`. Swift: `Controller.hapticsSending`, `HapticsPump.isSending`.
- Constants for the pad's USB audio function: product names, IDs, 4-channel order.

### Changed
- Report 0x32 is 142 bytes including the report ID (was 141), sized from the controller's
  descriptor when it declares the report. The control sub-packet defaults to `FE` plus
  five `0x10` buffer bytes (was `FE 00 00 00 00 FF`). Both changes follow dualsense-bridge.
- `SpeakerStream` (file playback in tactilectl and Tactile Lab) uses the new 0x36 layout and
  10.667 ms cadence with a 160 kb/s CBR default; tactilectl's default speaker volume is 0x64.

### Fixed
- Audio haptics after rumble: SDL documents `valid_flag0` bit 1 as disabling audio
  haptics. The rumble-off report sent when the 0x32 pump starts, and the neutral
  report sent while it runs, are now followed by a report with the bit clear.
- `TactileVersion.string` / `tactile_version_string()` reported 0.1.0; now 0.3.0.

### Verified in software only
- Byte-exact vectors for 0x32 (sequence and counter wrap), 0x36 (Bluetooth and USB),
  audio routing and the hand-back pair, generated by `tools/gen_vectors.py`.
- 0x32 and 0x36 cross-checked against public references: SDL and Linux implement
  neither. Sources and conflicts are listed in PROTOCOL.md. macOS's Opus encoder gives
  exactly 200-byte CBR frames. Nothing new
  was verified on hardware; see TESTING.md "Tactile 0.3 — engine hardware checklist".

## [0.2.0] — 2026-10-27

### Changed — Tactile Lab 1.1
- Liquid Glass layout: a sidebar of lab sections and connected controllers, the controller
  picker, test length and Stop All in the glass toolbar, and a floating status bar.
- Named controls light up as tinted glass; player cards are tinted with each player's colour.
- `scripts/release-lab.sh --signed-only` builds Developer ID signed downloads without notarization.

### Added — multiple controllers / split screen
- `PlayerSlots` (TactileCore): stable player numbers 1–8 keyed by controller identity;
  seats held across disconnects; assign/swap/release; `LightbarColor.player(_:)`.
- `PlayerAssigner` (Tactile): attaches to a `ControllerManager`, optional automatic
  player LEDs and lightbar colours.
- C ABI 0.2 (additive): `tactile_context_set_player_options`, `tactile_context_get_player`,
  `tactile_context_assign_player`, `tactile_context_release_player`,
  `tactile_controller_get_player`, `TACTILE_EVENT_PLAYER_CHANGED`. Player lights default
  off for C hosts.
- Bindings: Python `Context.player()/players()/assign_player()`, Unity
  `TactileManager.GetPlayer()/AssignPlayer()/PlayerChanged` and a split-screen sample,
  Godot `TactilePad.player` (all nodes share one context), Unreal per-player functions.
- Tactile Lab: Players tab, player chips in the header, `--scenario split`.

### Fixed
- `ControllerManager` could deadlock when a lifecycle event was emitted while an event
  stream was being cancelled (it yielded while holding the lock its onTermination
  handler takes). Emission now uses a separate lock.
- Tactile Lab controller artwork no longer shows a PlayStation logo.

### Added (experimental — gate 6, unverified protocol facts)
- `AudioSettings` on `OutputState`: headphone/speaker/mic volume and output path.
- `HIDDescriptor`: report-descriptor parser (sizes of every input/output/feature report).
- `SpeakerAudioReportBuilder` (report 0x36, configurable framing) and the new
  `TactileAudio` module: Opus encode/decode via the system codec, `SpeakerStream`,
  `MicUplinkDecoder`.
- `UplinkScanner` / `UplinkExtractor` to locate an Opus microphone stream in raw input.
- `FeatureSnapshot` + diff for Edge profile / stick-module research (read-only).
- `DeviceConnection.rawInputReports()` and `sendExperimentalOutputReport(_:)`.
- `Controller` experimental API and `tactilectl` commands: `descriptor`, `audio`,
  `speaker`, `mic-scan`, `mic-record`, `features`, `features-diff`.
- Not exposed through the C ABI yet.

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
