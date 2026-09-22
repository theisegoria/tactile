# Gate 5 receipt — engine bindings

The maintainer asked for all bindings at once (no controller available), rather
than one per approval.

| Binding | Sample | Evidence |
|---|---|---|
| Python ctypes (`bindings/python`) | `examples/demo.py` | `python3 bindings/python/tests/test_binding.py` → 4 tests OK (ABI, struct layouts 72/44/11 bytes, golden trigger bytes, error mapping) |
| Unity P/Invoke (`bindings/unity`) | `Samples~/Demo/TactileDemo.cs` | not compiled — no Unity/.NET toolchain on this machine |
| Godot 4 GDExtension (`bindings/godot`) | `demo/main.tscn` + `main.gd` | not compiled — needs a godot-cpp checkout |
| Unreal plugin (`bindings/unreal`) | `ATactileDemoActor` | not compiled — no Unreal install |

All four samples implement the same behaviour so they can be compared on hardware.
