#!/usr/bin/env bash
# Copies tactile.h and libCTactile.dylib into the plugin's ThirdParty folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
swift build -c release --product CTactile >/dev/null
BIN="$(swift build -c release --show-bin-path)"
DEST="bindings/unreal/TactileUE/Source/ThirdParty/CTactile"
cp Sources/CTactileHeaders/include/tactile.h "$DEST/include/"
cp "$BIN/libCTactile.dylib" "$DEST/lib/Mac/"
install_name_tool -id @rpath/libCTactile.dylib "$DEST/lib/Mac/libCTactile.dylib"
echo "installed into $DEST"
