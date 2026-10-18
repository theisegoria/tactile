#!/usr/bin/env bash
# Archive locally; only publish the download folder after every trust check passes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${TACTILE_NOTARY_PROFILE:-tactile}"
IDENTITY="${TACTILE_SIGN_IDENTITY:-Developer ID Application: Benjamin Haire (Q73Q75XA2B)}"
mkdir -p "$ROOT/build" "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/build/lab-release.XXXXXX")"
ARCHIVE="$WORK/Tactile Lab.xcarchive"
APP="$WORK/Tactile Lab.app"
DOWNLOAD="$WORK/download"
mkdir -p "$DOWNLOAD"
echo "Release work and verification logs: $WORK"
if [[ "${1:-}" == "--from-archive" ]]; then
  [[ -d "${2:-}/Products/Applications/Tactile Lab.app" ]] || { echo "Supply a valid archive path." >&2; exit 2; }
  ARCHIVE="$2"
  shift 2
else
  xcodebuild -project "$ROOT/TactileLab.xcodeproj" -scheme TactileLab \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/build/TactileLabRelease" -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="$IDENTITY" archive > "$WORK/archive.log" 2>&1 || {
    tail -80 "$WORK/archive.log"; exit 1;
  }
fi
ditto "$ARCHIVE/Products/Applications/Tactile Lab.app" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2> "$WORK/signature.txt"
codesign -dv --verbose=4 "$APP" 2> "$WORK/signing-details.txt"
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>> "$WORK/signature.txt"
python3 - "$APP" "$WORK" <<'PY'
import pathlib, plistlib, subprocess, sys
app, work = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
entitlements = plistlib.loads((work / 'entitlements.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'dev.tactile.lab'
assert info['LSMinimumSystemVersion'] == '27.0'
assert entitlements.get('com.apple.security.device.audio-input') is True
assert not entitlements.get('com.apple.security.get-task-allow', False)
assert '(runtime)' in (work / 'signing-details.txt').read_text()
assert 'Authority=Developer ID Application:' in (work / 'signing-details.txt').read_text()
arches = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Tactile Lab')], text=True).strip()
assert arches == 'arm64', arches
(work / 'archive-path.txt').write_text(str(app) + '\n')
PY
echo "Verified Developer ID signature, hardened runtime, audio entitlement and arm64 architecture."
echo "Archive: $ARCHIVE"
if [[ "${1:-}" == "--archive-only" ]]; then exit 0; fi

# Credentials are held in Keychain, never passed as command-line secrets.
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json > "$WORK/notary-history.json"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/submission.zip"
xcrun notarytool submit "$WORK/submission.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/notarization-app.json"
python3 - "$WORK/notarization-app.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('App notarization was not Accepted. Inspect the saved result before continuing.')
PY
xcrun stapler staple "$APP" > "$WORK/staple-app.txt" 2>&1
xcrun stapler validate "$APP" >> "$WORK/staple-app.txt" 2>&1
spctl --assess --type execute --verbose=4 "$APP" > "$WORK/gatekeeper-app.txt" 2>&1
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="Tactile-Lab-$VERSION-apple-silicon"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DOWNLOAD/$NAME.zip"
mkdir "$WORK/dmg-root"
ditto "$APP" "$WORK/dmg-root/Tactile Lab.app"
ln -s /Applications "$WORK/dmg-root/Applications"
cp "$ROOT/App/Installation.txt" "$WORK/dmg-root/Installation.txt"
hdiutil create -volname 'Tactile Lab' -srcfolder "$WORK/dmg-root" -format UDZO -ov "$DOWNLOAD/$NAME.dmg" > "$WORK/dmg-create.txt"
codesign --timestamp --sign "$IDENTITY" "$DOWNLOAD/$NAME.dmg"
xcrun notarytool submit "$DOWNLOAD/$NAME.dmg" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/notarization-dmg.json"
python3 - "$WORK/notarization-dmg.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    raise SystemExit('DMG notarization was not Accepted. Inspect the saved result before continuing.')
PY
xcrun stapler staple "$DOWNLOAD/$NAME.dmg" > "$WORK/staple-dmg.txt" 2>&1
xcrun stapler validate "$DOWNLOAD/$NAME.dmg" >> "$WORK/staple-dmg.txt" 2>&1
codesign --verify --verbose=2 "$DOWNLOAD/$NAME.dmg" 2> "$WORK/signature-dmg.txt"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DOWNLOAD/$NAME.dmg" > "$WORK/gatekeeper-dmg.txt" 2>&1
cp "$ROOT/App/Installation.txt" "$DOWNLOAD/Installation.txt"
(cd "$DOWNLOAD" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
mkdir -p "$DOWNLOAD/verification"
cp "$WORK"/notarization-*.json "$WORK"/staple-*.txt "$WORK"/gatekeeper-*.txt "$WORK"/signature*.txt "$WORK/signing-details.txt" "$WORK/entitlements.plist" "$DOWNLOAD/verification/"
DESTINATION="$ROOT/dist/TactileLab"
if [[ -e "$DESTINATION" ]]; then
  # Preserve the prior local download until the new one has passed all checks.
  mv "$DESTINATION" "$WORK/previous-download"
fi
mv "$DOWNLOAD" "$DESTINATION"
echo "Notarized, stapled downloads and checksums: $DESTINATION"
