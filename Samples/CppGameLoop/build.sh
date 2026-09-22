#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
swift build -c release --product CTactile >/dev/null
BIN="$(swift build -c release --show-bin-path)"
clang++ -std=c++17 -O2 -Wall -Wextra -I Sources/CTactileHeaders/include Samples/CppGameLoop/main.cpp \
  -L "$BIN" -lCTactile -Wl,-rpath,"$BIN" -o "$BIN/cpp-game-loop"
echo "built $BIN/cpp-game-loop"
