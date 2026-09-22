# Adversarial audit (2026-09-22)

Run as a multi-agent workflow: 7 area auditors (core, transport, haptics, facade/bridge, C ABI, bindings, tools/CI) each reported bugs with a concrete failure scenario; every finding went to an independent skeptic told to refute it (default: refuted); confirmed bugs were patched area by area with build + tests after each; a final agent re-ran the full verification suite.

**71 findings, 60 confirmed, 11 refuted.** No hardware was available; everything was reasoned from code, SDK interfaces and documented protocol facts.

## Confirmed and fixed

| Area | Severity | Location | Bug |
|---|---|---|---|
| facade | high | `Sources/Tactile/Controller.swift:155` | startHaptics racing stopHaptics leaves an orphaned real-time pump thread and rumble suppressed for good |
| facade | high | `Sources/Bridge/Bridge.swift:112` | Thumbstick and touchpad movement count as button edges, so the bridge matches the wrong controller |
| haptics | high | `Sources/TactileHaptics/Pump.swift:69` | metrics() traps on UInt64 underflow if called within the first tick after start() |
| haptics | high | `Sources/TactileHaptics/Quantizer.swift:34` | A NaN sample reaches Int8(v) and crashes the pump thread (softClip lets NaN through) |
| tools | high | `Samples/SwiftSample/Package.swift:11` | CI 'Swift sample app' step always fails: package identity comes from the checkout directory name |
| bindings | medium | `bindings/godot/SConstruct:9` | Godot build fails to link: godot-cpp defaults to a universal build on macOS, but libCTactile is arm64 only |
| bindings | medium | `bindings/godot/demo/tactile.gdextension:6` | The .gdextension library path doesn't match the file name SConstruct produces, so the extension never loads |
| bindings | medium | `bindings/python/tactile/__init__.py:377` | on_event() replace or remove frees the ctypes callback thunk while the library can still call it (use-after-free) |
| bindings | medium | `bindings/python/tactile/__init__.py:356` | A Context dropped without close() frees its callback while the native context keeps running and firing events |
| bindings | medium | `bindings/godot/src/tactile_pad.cpp:63` | TactilePad creates its context in _ready but destroys it in _exit_tree, so a re-added node never works again |
| bindings | medium | `bindings/unity/com.tactile.dualsense/Runtime/TactileManager.cs:125` | Engine wrappers stick to the first controller ever seen, and Unity reports other pads' disconnects as the main pad's |
| cabi | medium | `Sources/TactileCABI/Boxes.swift:176` | tactile_context_set_callback does not fence queued callbacks, so the old fn/user_data can be called after the call returns (use-after-free) |
| cabi | medium | `Sources/TactileCABI/Boxes.swift:79` | Controller handles are not invalidated by tactile_context_destroy: output calls still return OK, and haptics_start/play start a real-time pump thread that never stops |
| cabi | medium | `Sources/TactileCABI/Boxes.swift:200` | tactile_context_destroy does not drain or stop the per-controller output queues, so a queued output can land after neutralization |
| cabi | medium | `Sources/TactileCABI/Boxes.swift:201` | Destroy's callback drain races with an in-progress handle(): a callback can still be dispatched after callbackQueue.sync {} and even after destroy returns |
| cabi | medium | `Sources/TactileCABI/Exports.swift:233` | tactile_controller_neutralize leaves Controller's cached rumble in place, so rumble comes back on the next haptics_start/stop |
| core | medium | `Sources/TactileCore/Calibration.swift:75` | Gyro calibration subtracts the factory bias; current LNX (the cited source) sets gyro bias to 0 |
| core | medium | `Sources/TactileCore/TriggerEffect.swift:35` | Synthesized Codable lets TriggerEffect.bytes have any length; encodeCommon then misaligns the report or traps |
| facade | medium | `Sources/Tactile/ControllerManager.swift:144` | A late disconnect for an old deviceID tears down the controller's new live connection |
| facade | medium | `Sources/Tactile/Controller.swift:68` | Reconnect restarts haptics with the default framing instead of the caller's HapticsFraming |
| facade | medium | `Sources/Tactile/Controller.swift:120` | neutralize() keeps the stored rumble, so a later stopHaptics or startHaptics brings the rumble back |
| facade | medium | `Sources/Bridge/Bridge.swift:113` | MainActor.assumeIsolated in valueChangedHandler crashes when the app sets GCController.handlerQueue |
| facade | medium | `Sources/Bridge/Bridge.swift:111` | The bridge overwrites the app's extendedGamepad.valueChangedHandler, or is silently overwritten by it |
| haptics | medium | `Sources/TactileHaptics/Pump.swift:61` | stop() does not stop or join the pump thread, so a later start() can leave two pump threads rendering the same mixer |
| haptics | medium | `Sources/TactileHaptics/Mixer.swift:125` | stopAll() racing render() brings voices back to life |
| haptics | medium | `Sources/TactileHaptics/Resampler.swift:25` | Unvalidated input rate: infinite or huge rates trap, tiny rates hang forever, rate 0 loops forever |
| transport | medium | `Sources/TactileTransport/DeviceConnection.swift:156` | close()/neutralize() race: output sent after the neutral report can leave the controller rumbling |
| transport | medium | `Sources/TactileTransport/DeviceConnection.swift:309` | Rumble suppression also removes rumble from the neutral/close report, so rumble is never stopped |
| transport | medium | `Sources/TactileTransport/DeviceConnection.swift:144` | Exclusive seize is never released: close() keeps the HIDDeviceClient alive, and failed or dropped opens leak it |
| bindings | low | `bindings/unity/com.tactile.dualsense/Runtime/TactileController.cs:60` | WritePcm on the audio thread races Dispose on the main thread (use-after-release of the native handle) |
| bindings | low | `bindings/unity/com.tactile.dualsense/Runtime/TactileManager.cs:101` | The static event queue is shared by every TactileManager, so handles cross contexts and are released by the wrong owner |
| bindings | low | `bindings/unreal/install-thirdparty.sh:6` | Scripts ship a host-architecture-only libCTactile, which breaks universal engine builds |
| bindings | low | `bindings/python/tactile/__init__.py:183` | Python binding claims to mirror the C ABI one-to-one but has no tactile_haptics_get_metrics |
| cabi | low | `Sources/TactileCABI/Boxes.swift:166` | ControllerEvent.failed is dropped, so TACTILE_ERR_BUSY and open-time permission errors never reach the C host |
| cabi | low | `Sources/TactileCABI/Exports.swift:343` | tactile_haptics_write_pcm reports frames as queued while the pump is stopped; they play later as stale audio |
| cabi | low | `Sources/TactileCABI/Exports.swift:353` | tactile_haptics_get_metrics returns TACTILE_ERR_NOT_CONNECTED for a connected controller whose pump is stopped |
| cabi | low | `scripts/check-c-abi.sh:21` | `nm / grep -q` under `set -o pipefail` can report exports as missing when there are none |
| core | low | `Sources/TactileCore/TriggerEffect.swift:148` | multiplePositionVibration with all-zero amplitudes emits mode 0x26 with no active zones instead of Off (differs from the Nielk1 gist) |
| core | low | `Sources/TactileCore/InputReport.swift:134` | Battery error states report 5–100% instead of 0 / unknown |
| core | low | `Sources/TactileCore/RateLimiter.swift:15` | RateLimiter traps on a NaN rate |
| facade | low | `Sources/Tactile/Controller.swift:121` | neutralize() and stopHaptics() clear the SPSC stream from a non-consumer thread while the pump is reading it |
| facade | low | `Sources/Tactile/Controller.swift:112` | setRumble during startHaptics's window is lost, and reconnect sends stale rumble on 0x31 before suppression |
| facade | low | `Sources/Tactile/ControllerManager.swift:42` | events() can deliver .connected twice for the same controller |
| facade | low | `Sources/Tactile/ControllerManager.swift:92` | After shutdown() or close(), controllers still report isConnected, and a restart replays them as .connected with dead connections |
| haptics | low | `Sources/TactileHaptics/Mixer.swift:61` | stopAll() calls the consumer-only stream.clear() from arbitrary threads, breaking the SPSC contract and corrupting ring indices |
| haptics | low | `Sources/TactileHaptics/Effects.swift:51` | Voice length conversion traps for infinite, NaN or very large effect durations |
| haptics | low | `Sources/TactileHaptics/Mixer.swift:73` | The 'producer stopped' equality check starts playback early and bypasses the jitter-buffer prefill |
| haptics | low | `Sources/TactileHaptics/Effects.swift:75` | Texture grain envelope uses the unjittered interval, so grains start part-decayed or hold at full level |
| haptics | low | `Sources/TactileHaptics/AudioSources.swift:81` | The resampler tail is never flushed, so file playback and streamed PCM lose their last ~radius input samples |
| tools | low | `Samples/SwiftSample/Sources/TactileDemo/TactileDemoApp.swift:51` | Sample never tells the bridge about a disconnect: `c.address` is always nil in the .disconnected branch |
| tools | low | `Samples/SwiftSample/Sources/TactileDemo/TactileDemoApp.swift:33` | Demo app never shuts down its ControllerManager, so triggers, lightbar and LEDs stay set after quitting |
| tools | low | `Sources/tactile-probe/GameControllerProbe.swift:39` | gc probe releases the CHHapticEngine immediately, so the 300 ms test event is cut off (false negative) |
| tools | low | `Sources/tactilectl/Commands.swift:9` | `--hold inf` / huge values trap in Duration.seconds after output is applied, skipping the neutral restore |
| tools | low | `Sources/tactilectl/Commands.swift:158` | `haptic --effect X --repeat -1` crashes with an invalid Range after the haptics pump has started |
| tools | low | `Sources/tactilectl/Commands.swift:63` | `monitor` never prints stick or R2 movement unless a button changes |
| tools | low | `Sources/tactilectl/Commands.swift:116` | trigger side and numeric parameters are parsed leniently, so a typo sends a different effect than intended |
| tools | low | `Samples/SwiftSample/README.md:11` | README's app path is only correct for the new SwiftPM build system, not for Xcode 16 / Swift 6.0-6.1 |
| transport | low | `Sources/TactileTransport/DeviceConnection.swift:129` | Crash-recovery journal is cleared even when the recovery neutral report failed |
| transport | low | `Sources/TactileTransport/DeviceConnection.swift:234` | Bluetooth expected feature length adds 4 bytes, which breaks the stripped-ID detection in normalize() |
| transport | low | `Sources/TactileTransport/DeviceConnection.swift:302` | deferredFlush clears flushTask unconditionally, orphaning a newer deferred task |

## Refuted by the skeptics

| Area | Claim |
|---|---|
| core | Bluetooth feature-report lengths are modelled as payload + 4-byte CRC; per LNX the CRC sits inside the 41/20/64 bytes |
| core | IMUCalibration.apply traps when the gyro or accel arrays have fewer than 3 entries |
| core | LED brightness is written with no valid flag unless player LEDs are also set, contrary to PROTOCOL.md |
| transport | Feature-report CRC gate is bypassed: any Bluetooth report with a bad CRC is accepted with its CRC tail attached |
| transport | Input report-ID normalisation ignores length, so it misframes stripped reports whose first data byte equals the ID |
| transport | Monitor loop ignores .deviceRemoved and .deviceSeized notifications |
| transport | Reentrant sendNow lets concurrent sends reach the device out of order |
| transport | Discovery silently drops controllers when HIDDeviceClient init fails (for example, missing permission), so inputMonitoringDenied is never reported |
| haptics | Underrun metrics contradict their documentation: silent re-buffering ticks go uncounted, and every normal clip end counts as an underrun |
| facade | Stopping the pump does not wait for its thread, so a quick restart has two threads rendering the same mixer |
| tools | `leds` output (player LEDs, mute LED, brightness) is never restored on exit despite 'returned to neutral' and --hold semantics |

## Patches

| Area | Fixed | Skipped |
|---|---|---|
| core | 5 | 0 |
| transport | 6 | 0 |
| haptics | 10 | 0 |
| facade | 10 | 1 |
| cabi | 9 | 0 |
| bindings | 10 | 0 |
| tools | 9 | 0 |

One facade item was skipped because the haptics patch had already fixed it.

## Final verification

`swift build` clean · `swift test` 53 + 30 tests pass · `check-c-abi.sh` pass · Python binding 7 tests pass · C++ sample, Swift sample, XCFramework build.

## Follow-ups noted by patchers (not done)

- No test target yet for `Tactile`/`TactileBridge`/`tactilectl`; the facade and CLI fixes have no regression tests.
- An end-of-stream C call (`tactile_haptics_flush_pcm`) would let C producers play the last ~4.5 ms of a clip without the stall fallback.
- Opening a second `DeviceConnection` for the same controller shares its crash-journal key; a per-connection key would be cleaner.
- `scripts/build-xcframework.sh` leaves the shared release dylib as the last-built arch (x86_64); rebuild for the host afterwards.
