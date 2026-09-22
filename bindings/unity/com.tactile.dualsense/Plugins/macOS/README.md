Place the native library here. Recommended (universal arm64 + x86_64, needed for
"Intel 64-bit + Apple silicon" players): copy `CTactile.framework` from
`dist/CTactile.xcframework` (built by `scripts/build-xcframework.sh`).

For Apple silicon-only players and the Editor, the host-architecture dylib is
enough:

    swift build -c release --product CTactile
    cp "$(swift build -c release --show-bin-path)/libCTactile.dylib" Plugins/macOS/

(That dylib contains only the build machine's architecture; an Intel player
would fail to load it with DllNotFoundException.) In the Inspector, enable it
for macOS Standalone and the Editor. Unity's built-in DualSense support does not
do Bluetooth rumble or lightbar on macOS; this package does.
