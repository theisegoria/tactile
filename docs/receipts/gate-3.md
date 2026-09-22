# Gate 3 receipt — Bluetooth haptics

## Built

`TactileHaptics` (resampler, TPDF dither, SPSC ring, mixer with jitter buffer,
parametric effects, rumble emulation, time-constraint pump, metrics, AVAudioEngine
tap and file sources) and `tactilectl haptic <wav> | --mic | --effect`.

## Measurements (software, null sink — no radio in the loop)

`tactilectl haptic-bench 10` (release build, Apple silicon, macOS 27), 48 kHz tone
streamed in real time plus periodic clicks:

```
reports built=938 sent=938 dropped=0
underruns ticks=0 frames=0
wake lateness µs mean=5.3 p99=9.9 max=12.6
tick interval µs mean=10666.7 σ=1.6
send latency µs mean=0.3 p99=0.8 max=5.8
pump CPU=0.1% buffered=22.0 ms
resampler latency: 4.46 ms, dropped frames: 0
```

- Cadence: mean interval exactly 10 666.7 µs, σ 1.6 µs, worst wake 12.6 µs late.
- CPU: 0.1 % of one core for the pump thread.
- Underruns: 0 with the ~21 ms jitter buffer. (The first bench run without it
  showed 758 underrun ticks in 10 s; that led to the jitter buffer.)
- Software latency (streamed audio): 4.5 ms resampler + ~21 ms buffer + ≤ 10.7 ms
  tick ≈ 25–36 ms before HID/Bluetooth. Parametric effects: ≤ 10.7 ms.

**Not yet measured:** real `dispatchSetReportRequest` latency over Bluetooth,
end-to-end latency, and whether the 0x32 framing is right at all (🔬).

## Arbitration policy

While the pump runs, rumble is dropped from 0x31 and emulated on the voice coils in
the mixer (55 Hz heavy, 160 Hz light); triggers/LEDs stay on 0x31. On stop, the last
rumble returns to 0x31. To revisit after TESTING.md 3.5 shows whether 0x31 rumble
and 0x32 can coexist.

## Assumptions to check

All of `PROTOCOL.md §0x32` (🔬), channel mapping, signed samples.

## Failures

The jitter-buffer issue above (fixed).
