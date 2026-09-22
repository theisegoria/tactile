# Distribution

## Swift Package Manager

```swift
.package(url: "https://github.com/<you>/tactile.git", from: "0.1.0")
// products: Tactile (everything), TactileCore, TactileTransport, TactileHaptics, TactileBridge
```

## XCFramework for non-Swift hosts

`scripts/build-xcframework.sh` builds `libCTactile.dylib` for arm64 and x86_64,
wraps it in a framework with `tactile.h` and a module map, and produces
`dist/CTactile.xcframework` (plus a zip and its SwiftPM checksum).

## Signing and notarization (Developer ID)

```bash
# 1. Sign the framework and the host app (hardened runtime)
codesign --force --options runtime --timestamp --sign "Developer ID Application: NAME (TEAMID)" \
  dist/CTactile.xcframework/macos-arm64_x86_64/CTactile.framework
codesign --force --options runtime --timestamp --entitlements Support/App.entitlements \
  --sign "Developer ID Application: NAME (TEAMID)" MyApp.app

# 2. Notarize (store credentials once with `xcrun notarytool store-credentials tactile`)
ditto -c -k --keepParent MyApp.app MyApp.zip
xcrun notarytool submit MyApp.zip --keychain-profile tactile --wait

# 3. Staple
xcrun stapler staple MyApp.app
spctl --assess --type execute -vv MyApp.app
```

## Mac App Store

Use `Samples/SwiftSample/Support/TactileDemo-AppStore.entitlements` as the starting
point, sign with an Apple Distribution identity, and upload with Xcode or
`xcrun altool`/Transporter. See `docs/Sandboxing.md`.
