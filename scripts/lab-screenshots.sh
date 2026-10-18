#!/usr/bin/env bash
# Captures the simulated Tactile Lab UI, tab by tab, as PNGs for review.
# Usage: scripts/lab-screenshots.sh <out-dir> [scenario] [light|dark]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?output directory}"; SCENARIO="${2:-multiple}"; APPEARANCE="${3:-light}"
RESULT="$ROOT/build/lab-screenshots.xcresult"
mkdir -p "$OUT" "$ROOT/build"
rm -rf "$RESULT"
TEST_RUNNER_TACTILE_SCREENSHOT_TOUR=1 \
TEST_RUNNER_TACTILE_SCREENSHOT_SCENARIO="$SCENARIO" \
TEST_RUNNER_TACTILE_SCREENSHOT_APPEARANCE="$APPEARANCE" \
xcodebuild -project "$ROOT/TactileLab.xcodeproj" -scheme TactileLabUITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/TactileLabTestDerivedData" \
  -resultBundlePath "$RESULT" \
  -only-testing:TactileLabUITests/ScreenshotTour test > "$ROOT/build/lab-screenshots.log" 2>&1 || {
  tail -40 "$ROOT/build/lab-screenshots.log"; exit 1; }
EXPORT="$(mktemp -d)"
trap 'rm -rf "$EXPORT"' EXIT
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$EXPORT" >/dev/null
# Move exported files into OUT under their attachment names ("light-tab1.png").
python3 - "$EXPORT" "$OUT" <<'PY'
import json, os, shutil, sys
src_dir, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src_dir, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        src = os.path.join(src_dir, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName", a["exportedFileName"]).split("_0_")[0]
        if os.path.exists(src):
            shutil.move(src, os.path.join(out, name + ".png"))
PY
ls "$OUT"
