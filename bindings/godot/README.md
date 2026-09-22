# Tactile for Godot 4 (GDExtension)

Adds a `TactilePad` node (Godot proposal #12087 asks for this in core). Build:

```bash
swift build -c release --product CTactile            # repository root
cd bindings/godot
git clone -b 4.3 https://github.com/godotengine/godot-cpp
scons platform=macos target=template_debug
cp ../../.build/out/Products/Release/libCTactile.dylib demo/bin/
godot --path demo
```

The node polls in `_process`, so signals and state are main-thread only; output
calls never block. Not compiled by the author (no godot-cpp checkout in CI).
