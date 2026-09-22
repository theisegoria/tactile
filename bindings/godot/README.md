# Tactile for Godot 4 (GDExtension)

Adds a `TactilePad` node (Godot proposal #12087 asks for this in core). Build:

```bash
swift build -c release --product CTactile            # repository root
cd bindings/godot
git clone -b 4.3 https://github.com/godotengine/godot-cpp
scons platform=macos target=template_debug           # arch defaults to the host (arm64 or x86_64)
cp ../../.build/out/Products/Release/libCTactile.dylib demo/bin/
godot --path demo
```

The plain `swift build` produces a host-architecture-only `libCTactile.dylib`,
so the SConstruct builds the extension for the host architecture too (godot-cpp
would otherwise default to a universal build and fail to link the x86_64 slice).
For a universal export, build a universal library and point `TACTILE_BIN` at it
(the per-arch builds share the default products directory, so rerun the plain
`swift build -c release --product CTactile` afterwards for a host library there):

```bash
U="$PWD/.build/universal"; mkdir -p "$U"                # repository root
for a in arm64 x86_64; do
  swift build -c release --arch $a --product CTactile
  cp "$(swift build -c release --arch $a --show-bin-path)/libCTactile.dylib" "$U/libCTactile-$a.dylib"
done
lipo -create "$U"/libCTactile-arm64.dylib "$U"/libCTactile-x86_64.dylib -output "$U/libCTactile.dylib"
install_name_tool -id @rpath/libCTactile.dylib "$U/libCTactile.dylib"
cd bindings/godot && TACTILE_BIN="$U" scons platform=macos arch=universal target=template_debug
cp "$U/libCTactile.dylib" demo/bin/
```

The output is named `demo/bin/libtactile_godot.macos.<target>.dylib` (no arch
component) to match `demo/tactile.gdextension`.

`TactilePad` opens its context when it enters the tree and closes it (restoring
neutral output) when it leaves, so it survives being removed and re-added. It
follows whichever DualSense is reporting: if its controller goes away and
another one is connected, it switches to that one (emitting
`controller_disconnected` then `controller_connected`).

The node polls in `_process`, so signals and state are main-thread only; output
calls never block. Not compiled by the author (no godot-cpp checkout in CI).
