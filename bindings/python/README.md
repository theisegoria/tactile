# Tactile for Python (ctypes)

```bash
swift build -c release --product CTactile      # from the repository root
python3 bindings/python/tests/test_binding.py  # hardware-free checks
python3 bindings/python/examples/demo.py       # needs a controller + Input Monitoring
```

The package finds `libCTactile.dylib` via `$TACTILE_LIB`, next to the package, or
the SwiftPM build directory. Event callbacks run on a library thread.

`Context.on_event` may be called any number of times (including from a
callback); the context keeps one native callback for its whole life. Prefer
`with tactile.Context() as ctx:`; a Context dropped without `close()` is still
destroyed (output neutralized) once it and every `Controller` taken from it are
garbage, or at interpreter exit. `Controller.haptics_metrics()` reads the
haptics pump statistics.

## C ABI 0.4

| C function | Python |
|---|---|
| `tactile_trigger_from_preset` | `TriggerEffect.preset(TRIGGER_PRESET_*)` |
| `tactile_pattern_load_file` / `_duration` / `_render` / `_free` | `Pattern.load(path)`, `.duration`, `.render()` (freed with the object) |
| `tactile_pattern_play` / `_stop` / `_is_playing` | `Controller.play_pattern(p)`, `.stop_pattern()`, `.pattern_playing` |
| `tactile_profile_apply_file` / `_json` | `Controller.apply_profile(path)`, `.apply_profile_json(text)` |

Patterns are `.tactilepattern` files (Tactile Lab's Composer saves them);
profiles are `.tactileprofile` files (Tactile Lab's Profiles screen exports
them). The tests cover presets, offline rendering and argument checks only;
pattern playback and profile output have not run on a controller.
