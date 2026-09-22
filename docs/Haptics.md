# Bluetooth audio haptics

Pipeline:

```
float PCM (any rate/channels) ─┐
AVAudioEngine tap / file ──────┼─ PCMInput: windowed-sinc resample → 3 kHz stereo
                               ▼
                         SPSCRingBuffer (lock-free, 1 s)
                               ▼
parametric voices ──► HapticsMixer.render(32 frames) ◄── rumble emulation
                               ▼  TPDF dither → int8
                         HapticsReportBuilder (0x32, CRC)
                               ▼
     HapticsPump thread (time-constraint policy, mach_absolute_time grid, 10.667 ms)
                               ▼
               sink → serial sender task → HIDDeviceClient.dispatchSetReportRequest
```

- **Underruns send silence, never stale data.** Missing stream frames are zero-filled.
- **Idle:** after 8 silent reports the pump stops sending (saves radio time) and
  resumes as soon as anything plays.
- **Back-pressure:** at most 3 reports in flight; beyond that ticks are dropped and
  counted rather than queued, so haptics never lag behind a stalled link.
- **Latency budget:** resampler group delay (≈ 4.5 ms at 48 kHz input) + queue
  (whatever is buffered; file playback targets 200 ms, live taps are small) + up
  to one 10.67 ms tick + Bluetooth.

## Rumble / haptics arbitration policy

The DualSense's "rumble" is itself emulated on the voice coils by the firmware.
Until gate 3 proves that 0x31 rumble and the 0x32 stream mix cleanly, Tactile
**arbitrates**: while the haptics pump runs, rumble is removed from 0x31 (its valid
flags are left clear) and emulated in the mixer as 55 Hz (heavy) and 160 Hz (light)
tones. When the pump stops, the last requested rumble goes back to 0x31. Trigger,
LED and lightbar output are unaffected. *To be confirmed by TESTING.md 3.5.*

## Metrics

`Controller.hapticsMetrics()` / `tactile_haptics_get_metrics`: reports built/sent/
dropped, underrun ticks and frames, wake lateness (mean/p99/max), tick interval mean
and σ (jitter), send latency (mean/p99/max, build→set-report completion), pump CPU %.
Measured values on hardware belong in `docs/receipts/gate-3.md`.

## Framing uncertainty

Every unconfirmed detail of report 0x32 lives in `HapticsFraming` (nibble order,
tag, sub-packet headers, control payload, signed samples) so the first hardware
session can find the working combination without code changes.
