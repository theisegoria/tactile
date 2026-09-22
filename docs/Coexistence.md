# Coexisting with other writers

A DualSense output report carries the complete state for every field whose valid
flag is set. When several processes write, **the last write wins**. Possible writers:

- macOS's own GameController stack (`gamecontrollerd`) — lightbar/player colour,
  adaptive triggers and haptics set through GameController.
- Steam (Steam Input uses HIDAPI; it exposes virtual pads marked
  `kIOHIDVirtualHIDevice` and probably writes output reports).
- Other utilities (DualSenseM, DS4Windows-like tools, browsers via WebHID).

## Modes

| | Shared (default) | Exclusive (`--exclusive`, `AccessMode.exclusive`) |
|---|---|---|
| Mechanism | normal open | `HIDDeviceClient.seizeDevice()` |
| GameController / Steam see the pad | yes | **no** |
| Standard input | from GameController or Tactile | **Tactile only** (`inputEvents()`) |
| Output conflicts | possible; detected and reported | none |
| Use when | augmenting a GameController-based game | a dedicated app or engine owning the pad |

## What Tactile does in shared mode

- **Owns only what you set.** A field you never set keeps its valid flag clear, so
  Tactile does not stomp on other writers' lightbar or triggers.
- **Detection:** `Controller.conflicts()` / `DeviceConnection.conflicts()` scan the
  IORegistry for other processes with an `IOHIDLibUserClient` on the same device
  (process name and pid) and for virtual twins (Steam Input). Detection is
  read-only and advisory.
- **Optional re-assertion:** `ConnectionOptions.reassertInterval` re-sends owned
  state periodically so an overwrite is corrected within that interval. Off by
  default because two re-asserting writers would fight.

Gate-0 hardware findings on which of these actually write, and when, go in
`docs/receipts/gate-0.md`.
