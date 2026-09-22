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
