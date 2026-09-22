# Thread-safety

## Swift API

| Type | Guarantee |
|---|---|
| `TactileCore` value types (`InputParser`, `OutputReportBuilder`, `TriggerEffect`, …) | Pure values; use freely, but a builder instance holds a sequence counter — one per device, not shared across threads without synchronisation. |
| `DeviceConnection` | `actor`; every method is safe from any task. |
| `DeviceDiscovery`, `ControllerManager`, `Controller` | `Sendable`; safe from any thread/task. |
| `HapticsMixer.play/setRumble/setGain/stopAll` | Any thread (short mutex). `stopAll` stops voices and rumble at once and *requests* a stream flush, which the pump performs at the start of its next block. |
| `HapticsMixer.stream` (`SPSCRingBuffer`) | **One producer thread and one consumer (the pump).** Lock-free; producer may be an audio render callback. `read`, `clear` and `applyPendingClear` are consumer-only; `requestClear` is callable from any thread. |
| `PCMInput` | One producer thread per instance. |
| `HapticsPump` | `start`/`stop`/`metrics`/`sendWhileIdle` from any thread; the pump runs on its own time-constraint thread. `stop` waits (at most about one 10.67 ms period) for the thread's last pass, except when called on the pump thread itself. |
| `ControllerBridge` | `@MainActor`. |

## C ABI (`tactile.h`)

| Function | Thread-safe | Blocks | Notes |
|---|---|---|---|
| `tactile_abi_version`, `tactile_version_string`, `tactile_result_string` | yes | no | static data |
| `tactile_permission_status` | yes | no | |
| `tactile_permission_request` | yes | may show a system prompt | call from the main thread in apps |
| `tactile_context_create` | yes | no | starts discovery in the background |
| `tactile_context_destroy` | yes | **yes** (neutralises and closes every controller) | never from a callback; each context destroyed once; queued output is applied before the neutral report; afterwards no callback runs and controller handles return `TACTILE_ERR_NOT_CONNECTED` |
| `tactile_context_set_callback` | yes | until a running call of the previous callback returns | callbacks run serially on an internal dispatch queue (not Swift's cooperative pool); briefly-blocking calls are allowed inside, `tactile_context_destroy` is not. Once it returns (from outside a callback) the previous callback and `user_data` are never used again |
| `tactile_context_controller_count`, `tactile_context_get_controller` | yes | no | returned handle is retained |
| `tactile_context_wait_for_controller` | yes | **yes**, up to timeout | not on a UI/render thread |
| `tactile_controller_retain`, `_release` | yes | no | atomic ref count |
| `tactile_controller_get_info` | yes | briefly (actor hop) | not in a per-frame hot path |
| `tactile_controller_get_input` | yes | no | copies the latest snapshot |
| `tactile_controller_set_lightbar/_player_leds/_mute_led/_rumble/_trigger/_neutralize` | yes | no | enqueued; applied in order; rate-limited and coalesced |
| `tactile_controller_last_error` | yes | no | read-and-clear |
| `tactile_trigger_*` | yes | no | pure |
| `tactile_haptics_start`, `_stop` | yes | briefly | |
| `tactile_haptics_play` | yes | no | |
| `tactile_haptics_write_pcm` | **one producer thread per controller** | no | frames beyond buffer capacity are dropped and counted; returns 0 (queues nothing) while haptics are stopped |
| `tactile_haptics_get_metrics` | yes | no | all zero while haptics are stopped |
