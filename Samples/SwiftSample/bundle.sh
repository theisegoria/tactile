#!/usr/bin/env bash
# Builds TactileDemo.app. Usage: ./bundle.sh [developer-id|app-store] [signing identity]
# Without an identity the app is ad-hoc signed (fine for local testing).
# The finished app is always at .build/TactileDemo.app, whatever build system the
# toolchain uses (--show-bin-path differs between SwiftPM's native backend and
# swift-build).
set -euo pipefail
cd "$(dirname "$0")"
FLAVOR="${1:-developer-id}"
IDENTITY="${2:--}"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=".build/TactileDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/TactileDemo" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
ENT="Support/TactileDemo-DeveloperID.entitlements"
[ "$FLAVOR" = "app-store" ] && ENT="Support/TactileDemo-AppStore.entitlements"
codesign --force --options runtime --entitlements "$ENT" --sign "$IDENTITY" "$APP"
echo "built $(pwd)/$APP ($FLAVOR)"
