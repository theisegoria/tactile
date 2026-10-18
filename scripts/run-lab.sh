#!/usr/bin/env bash
# Build a real native app bundle, then launch or focus it. Never kills a process.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${TACTILE_DERIVED_DATA:-$ROOT/build/TactileLabDerivedData}"
CONFIG="${TACTILE_CONFIGURATION:-Debug}"
BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then BUILD_ONLY=1; shift; fi
mkdir -p "$ROOT/build"
xcodebuild -project "$ROOT/TactileLab.xcodeproj" -scheme TactileLab \
  -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" build > "$ROOT/build/tactile-lab-build.log" 2>&1 || {
  tail -80 "$ROOT/build/tactile-lab-build.log"
  exit 1
}
APP="$DERIVED/Build/Products/$CONFIG/Tactile Lab.app"
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
echo "Built $APP"
if [[ "$BUILD_ONLY" == 1 ]]; then exit 0; fi
if pgrep -x 'Tactile Lab' >/dev/null; then
  echo "Tactile Lab is already running; focusing it. Quit it yourself to load the newly built version."
  open -a "$APP"
else
  open "$APP" --args "$@"
fi
