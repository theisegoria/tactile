# Engine bindings (gate 5)

Thin layers over the C ABI (`Sources/CTactileHeaders/include/tactile.h`). Each ships
a sample that does the same thing: poll input, Cross → haptic click, Circle → toggle
a weapon effect on R2, left stick → lightbar.

| Binding | Path | Verified here |
|---|---|---|
| Python (ctypes) | `python/` | ✅ hardware-free tests run against the real dylib |
| Unity (P/Invoke, UPM) | `unity/com.tactile.dualsense/` | ❌ not compiled (no Unity/.NET toolchain) |
| Godot 4 (GDExtension) | `godot/` | ❌ not compiled (needs godot-cpp) |
| Unreal (plugin module) | `unreal/TactileUE/` | ❌ not compiled (no Unreal) |
