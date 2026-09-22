Place the native library here:

    swift build -c release --product CTactile
    cp "$(swift build -c release --show-bin-path)/libCTactile.dylib" Plugins/macOS/

or copy `CTactile.framework` from `dist/CTactile.xcframework` (built by
`scripts/build-xcframework.sh`). In the Inspector, enable it for macOS Standalone
and the Editor. Unity's built-in DualSense support does not do Bluetooth rumble or
lightbar on macOS; this package does.
