# Tactile for Python (ctypes)

```bash
swift build -c release --product CTactile      # from the repository root
python3 bindings/python/tests/test_binding.py  # hardware-free checks
python3 bindings/python/examples/demo.py       # needs a controller + Input Monitoring
```

The package finds `libCTactile.dylib` via `$TACTILE_LIB`, next to the package, or
the SwiftPM build directory. Event callbacks run on a library thread.
