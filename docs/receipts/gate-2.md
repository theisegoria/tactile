# Gate 2 receipt — transport, bridge and basic output

## Built

- `TactileTransport`: CoreHID discovery (`DeviceDiscovery`), `DeviceConnection`
  actor (open → firmware → pairing → calibration; input fan-out; owned-state output
  with rate limit 125/s and coalescing; CRC gate; neutral on close; crash journal;
  optional re-assert), `InputMonitoringPermission`, `ConflictDetector`.
- Shared (default) and exclusive (`seizeDevice()`) modes.
- `TactileBridge.ControllerBridge`: uniqueness / input-correlation matching.
- `Tactile.ControllerManager` / `Controller`: stable objects across reconnects,
  owned output re-applied on reconnect.
- `tactilectl`: `list`, `monitor`, `info`, `light`, `leds`, `trigger`, `rumble`,
  plus `conflicts`, `permission`; Ctrl-C restores neutral output.

## Evidence

Hardware logs: **pending** (controller not connected; Input Monitoring denied for
this process). What was verified:

```
$ swift run tactilectl info
error: Input Monitoring permission is denied. Run `tactilectl permission`.
```

i.e. the permission failure path produces the intended actionable error.

## Conflict-detection behaviour

`ConflictDetector.scan` walks IOHIDDevice services for the VID/PID (matching the
serial number when known), lists children with `IOUserClientCreator`
(`pid N, name`), excludes our own pid, and counts `HIDVirtualDevice` twins. Known
kinds: `gamecontrollerd` → GameController daemon, `*steam*` → Steam. Advisory only.

## Assumptions to check

TESTING.md §Gate 2, especially 2.3 (Edge bit order), 2.5 (brightness), 2.9
(exclusive mode hides the pad from GameController), 2.11 (crash recovery).

## PROTOCOL.md changes

None beyond gate 1.
