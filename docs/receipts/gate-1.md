# Gate 1 receipt — protocol core

`TactileCore`: CRC-32; parsers for 0x01 (USB full, Bluetooth reduced) and 0x31,
Edge buttons; IMU calibration; 0x09 pairing; 0x20 firmware; feature gating;
builders for 0x31/0x02 and 0x32; all trigger effects; LED encodings; rate limiter.
Pure Swift, no imports beyond the standard library, no force unwraps.

## Test output

```
$ swift test
✔ Test run with 46 tests in 7 suites passed after 0.003 seconds.   (TactileCoreTests)
✔ Test run with 16 tests in 5 suites passed after 0.360 seconds.   (TactileHapticsTests)
```

## Vector sources

| Vector | Source |
|---|---|
| CRC `"123456789"` → `0xCBF43926` | standard CRC-32 check value |
| CRC seed `crc32([0xA2])` = `0xEADA2D49` | zlib, `tools/gen_vectors.py` |
| BT 0x31 input (full) and Edge variant; USB 0x01 input | synthesised from the documented layout (LNX/SDL facts) by `tools/gen_vectors.py`, CRC via zlib |
| BT 0x01 reduced input | SDL simple-state layout, hand-built |
| 0x05 calibration and its maths | documented layout (LNX facts); expected deg/s and g computed by hand |
| 0x09 pairing over BT with 0xA3 CRC | example locally administered MAC 02:11:22:33:44:55; layout from LNX; `tools/gen_vectors.py` |
| 0x20 firmware | documented offsets (LNX); `tools/gen_vectors.py` |
| 0x31 / 0x02 output (v2 and legacy rumble, sequence wrap) | documented common block (LNX/SDL); `tools/gen_vectors.py` |
| Trigger effects | formulas from NLK gist; multi-zone values from `tools/gen_vectors.py` (Python `round` is half-to-even, matching C# `Math.Round`) |
| 0x32 haptics | documented facts (SAX), clean-room; `tools/gen_vectors.py` |

`tools/gen_vectors.py` is an independent Python implementation of the documented
layouts; agreement between it and the Swift code guards against transcription
errors, **not** against errors in the documented facts themselves. Device captures
will replace or confirm these vectors at gates 2–3.

## Assumptions to check

- Update-version (offset 44) gating for vibration v2 (differs from the prompt's wording).
- LED brightness byte has no valid flag.
- Status byte 53 headphone/mic bits.

## Failures

One test vector was mistyped (hat nibble `0xF` = released) and fixed in the next
commit (`Fix reduced-report test vector`).
