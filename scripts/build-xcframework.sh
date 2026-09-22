#!/usr/bin/env bash
# Builds dist/CTactile.xcframework (universal arm64 + x86_64 macOS framework
# wrapping libCTactile.dylib and tactile.h), a zip, and its SwiftPM checksum.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS=(${ARCHS:-arm64 x86_64})
DIST=dist
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST/CTactile.xcframework" "$DIST/CTactile.xcframework.zip"
mkdir -p "$DIST"

LIBS=()
for arch in "${ARCHS[@]}"; do
  # Build products for different archs can share a directory; copy each out.
  swift build -c release --arch "$arch" --product CTactile >/dev/null
  cp "$(swift build -c release --arch "$arch" --show-bin-path)/libCTactile.dylib" "$WORK/libCTactile-$arch.dylib"
  LIBS+=("$WORK/libCTactile-$arch.dylib")
done

FW="$WORK/CTactile.framework"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Modules" "$FW/Versions/A/Resources"
lipo -create "${LIBS[@]}" -output "$FW/Versions/A/CTactile"
install_name_tool -id @rpath/CTactile.framework/Versions/A/CTactile "$FW/Versions/A/CTactile"
cp Sources/CTactileHeaders/include/tactile.h "$FW/Versions/A/Headers/"
cat > "$FW/Versions/A/Modules/module.modulemap" <<'MAP'
framework module CTactile {
  umbrella header "tactile.h"
  export *
}
MAP
VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/Tactile/Exports.swift)"
cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.tactile.CTactile</string>
  <key>CFBundleName</key><string>CTactile</string>
  <key>CFBundleExecutable</key><string>CTactile</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
(cd "$FW/Versions" && ln -s A Current)
(cd "$FW" && ln -s Versions/Current/CTactile CTactile && ln -s Versions/Current/Headers Headers \
  && ln -s Versions/Current/Modules Modules && ln -s Versions/Current/Resources Resources)
codesign --force --sign "${SIGN_IDENTITY:--}" "$FW" >/dev/null 2>&1

xcodebuild -create-xcframework -framework "$FW" -output "$DIST/CTactile.xcframework" >/dev/null
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent CTactile.xcframework CTactile.xcframework.zip)
echo "built $DIST/CTactile.xcframework ($(lipo -archs "$FW/Versions/A/CTactile"))"
echo "checksum: $(swift package compute-checksum "$DIST/CTactile.xcframework.zip")"
