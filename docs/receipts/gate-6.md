# Gate 6 receipt — stretch research (experimental code, no hardware)

The prompt says to implement only what can be verified on hardware. The
maintainer has no controller and asked for the gate-6 code anyway, so it is
implemented as **experimental**: clearly labelled APIs, every uncertain detail
configurable, read-only where a mistake could persist on the device.

## What was built

| Piece | Where | Tested without hardware |
|---|---|---|
| Audio volume/routing fields (0x31 bytes 4–7, `valid_flag0` bits 4–7) | `TactileCore/AudioSettings.swift` | ✅ byte-level tests |
| HID report-descriptor parser (sizes of all reports, vendor pages, push/pop, long items) | `TactileCore/HIDDescriptor.swift` | ✅ |
| Report 0x36 speaker framing (seq/tag, length prefix none/u8/u16, CRC) | `TactileCore/SpeakerAudioReport.swift` | ✅ |
| Opus TOC decoding, uplink scanner and extractor | `TactileCore/Opus.swift` | ✅ synthetic and real-encoder uplinks |
| Feature-report snapshot + diff | `TactileCore/FeatureSnapshot.swift` | ✅ |
| Opus encode/decode via AudioToolbox (no dependency) | `TactileAudio/OpusCodec.swift` | ✅ round trip at 48 kHz stereo and 24 kHz mono |
| Speaker streaming (file → 48 kHz stereo → Opus → 0x36, 10 ms pacing) | `TactileAudio/SpeakerStream.swift` | ✅ with a fake sender |
| Mic uplink decode to WAV | `TactileAudio/MicUplink.swift` | ✅ scanner → decoder → WAV on synthetic reports |
| Raw input stream; CRC-gated, rate-capped raw output | `TactileTransport/DeviceConnection.swift` | builds; exercised through facade tests only indirectly |
| Controller API + `tactilectl` commands | `Tactile/Controller+Experimental.swift`, `tactilectl/ExperimentalCommands.swift` | `features-diff` run end to end |

## Findings from software alone

- **macOS can encode and decode Opus natively** (`kAudioFormatOpus` through
  `AVAudioConverter`), so no libopus dependency is needed.
- For 48 kHz stereo 10 ms frames the system encoder emits TOC byte `0xF4`
  (config 30 = CELT fullband 10 ms, stereo) — exactly the format the lead
  describes. 24 kHz mono gives `0x60` (hybrid SWB 10 ms).
- At 96 kb/s packets are ~85–100 bytes after a larger first packet (~210 B), so a
  0x36 report needs roughly 100+ bytes of payload; `SpeakerStream` drops (never
  truncates) packets that do not fit and reports it.
- The uplink scanner's first design rejected real Opus from a steady tone (the
  byte after the TOC barely varies); it now compares the whole packet body minus
  the CRC. Digital silence may still produce identical packets — talk while scanning.

## Unknowns that only hardware can settle

Whether 0x36 exists in the descriptor and its size; the real 0x36 framing; which
output path values work; whether audio must be enabled before the uplink appears
and which report carries it; what Edge profile switches change. TESTING.md §Gate 6
lists the steps.

## PROTOCOL.md changes

"Research leads" replaced by "Gate 6 — experimental", listing each fact, its
source and status.
