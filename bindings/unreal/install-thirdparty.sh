#!/usr/bin/env bash
# Copies tactile.h and a universal (arm64 + x86_64) libCTactile.dylib into the
# plugin's ThirdParty folder. Unreal Mac targets link both slices, and a plain
# `swift build` only produces the host architecture. Override with e.g.
# ARCHS=arm64 for a single-architecture project.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ARCHS=(${ARCHS:-arm64 x86_64})
DEST="bindings/unreal/TactileUE/Source/ThirdParty/CTactile"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LIBS=()
for arch in "${ARCHS[@]}"; do
  # Build products for different archs can share a directory; copy each out.
  swift build -c release --arch "$arch" --product CTactile >/dev/null
  cp "$(swift build -c release --arch "$arch" --show-bin-path)/libCTactile.dylib" "$WORK/libCTactile-$arch.dylib"
  LIBS+=("$WORK/libCTactile-$arch.dylib")
done
# The per-arch builds share the default products directory; rebuild for the host
# so it holds a host library again for the other bindings and tests.
swift build -c release --product CTactile >/dev/null

mkdir -p "$DEST/include" "$DEST/lib/Mac"
cp Sources/CTactileHeaders/include/tactile.h "$DEST/include/"
lipo -create "${LIBS[@]}" -output "$DEST/lib/Mac/libCTactile.dylib"
install_name_tool -id @rpath/libCTactile.dylib "$DEST/lib/Mac/libCTactile.dylib"
codesign --force --sign "${SIGN_IDENTITY:--}" "$DEST/lib/Mac/libCTactile.dylib" >/dev/null 2>&1 || true
echo "installed into $DEST ($(lipo -archs "$DEST/lib/Mac/libCTactile.dylib"))"
