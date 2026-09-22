# Tactile for Unity (P/Invoke)

UPM package `com.tactile.dualsense`. Add it via Package Manager › Add package from
disk (`bindings/unity/com.tactile.dualsense/package.json`), drop the native library
into `Plugins/macOS` (see its README), add `TactileManager` to a GameObject and
import the Demo sample.

- Structs mirror `tactile.h` exactly (72-byte input state, 44-byte info).
- Lifecycle callbacks arrive on a native thread and are queued to `Update()`.
- Output calls never block, so they are safe to call every frame (the library
  rate-limits and coalesces).
- Untested in Unity by the author (no Unity install); compile errors or runtime
  issues should be reported.
