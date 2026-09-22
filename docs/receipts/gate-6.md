# Gate 6 — stretch research plan (report only; nothing implemented)

Implement only what can be verified on hardware.

## Speaker / headphone / mic audio over Bluetooth

Lead (🔬, unlicensed repository, facts only): speaker audio in output report
`0x36` as Opus (CELT) 48 kHz stereo, 10 ms frames; mic uplink as Opus 24 kHz.

Plan:
1. Parse the report descriptor from `tactile-probe list` for report `0x36` size and
   any uplink report IDs.
2. Enable audio routing via the 0x31 audio fields (bytes 4–7: headphone/speaker/mic
   volume, audio control; `valid_flag0` bits 4–7) — needs raw-byte access; add an
   experimental `OutputState.rawAudio` only once confirmed.
3. Encode a 1 kHz tone with libopus (would be the first third-party dependency;
   keep it in a separate optional target) and send at 100 Hz; listen.
4. Capture input reports while speaking into the controller mic; look for a
   periodic report with Opus TOC bytes.

## Edge profiles and stick modules

1. Dump every feature report ID declared in the Edge descriptor (USB and BT) with
   `tactile-probe features` extended to arbitrary IDs.
2. Switch profiles on the controller (Fn + face buttons) and diff feature dumps.
3. Swap stick modules if available and diff again.

Evidence and results go in this file; facts that pass go into `PROTOCOL.md`.
