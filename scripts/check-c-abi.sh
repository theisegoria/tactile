#!/usr/bin/env bash
# Verifies the public C header: strict C11 and C++17 compiles, layout asserts,
# link against libCTactile, and hardware-free behaviour checks.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product CTactile >/dev/null
BIN="$(swift build --show-bin-path)"
INC="Sources/CTactileHeaders/include"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-Wall -Wextra -Werror -pedantic -I "$INC")
clang -std=c11 "${FLAGS[@]}" -x c -fsyntax-only "$INC/tactile.h"
clang++ -std=c++17 "${FLAGS[@]}" -x c++ -fsyntax-only "$INC/tactile.h"
clang -std=c11 "${FLAGS[@]}" Tests/CABI/header_check.c -L "$BIN" -lCTactile -Wl,-rpath,"$BIN" -o "$OUT/check_c"
clang++ -std=c++17 "${FLAGS[@]}" -x c++ Tests/CABI/header_check.c -L "$BIN" -lCTactile -Wl,-rpath,"$BIN" -o "$OUT/check_cpp"
"$OUT/check_c"
"$OUT/check_cpp"
# Every declared function must be exported by the dylib.
missing=0
for fn in $(grep -oE '\btactile_[a-z_]+\(' "$INC/tactile.h" | tr -d '(' | sort -u); do
  if ! nm -gU "$BIN/libCTactile.dylib" | grep -q " _$fn\$"; then echo "missing export: $fn"; missing=1; fi
done
[ $missing -eq 0 ] && echo "all header functions exported"
exit $missing
