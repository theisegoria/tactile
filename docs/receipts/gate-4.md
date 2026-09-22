# Gate 4 receipt — C ABI and samples

## Built

- `libCTactile.dylib` (product `CTactile`) with `Sources/CTactileHeaders/include/tactile.h`:
  opaque ref-counted handles, `struct_size`-prefixed structs, ABI version 0.1,
  non-blocking output queues, non-blocking input snapshots, trigger builders,
  haptics calls, result strings.
- `scripts/build-xcframework.sh` → `dist/CTactile.xcframework` (arm64 + x86_64) and zip
  with SwiftPM checksum.
- Samples: `Samples/CppGameLoop` (C++17 game loop), `Samples/SwiftSample`
  (SwiftUI app with Info.plist + Developer ID / App Store entitlements).

## Evidence

```
$ ./scripts/check-c-abi.sh
C ABI check passed (ABI 0.1, library 0.1.0)      # C11 build
C ABI check passed (ABI 0.1, library 0.1.0)      # C++17 build
all header functions exported

$ ./Samples/CppGameLoop/build.sh
built …/.build/out/Products/Release/cpp-game-loop

$ ./Samples/SwiftSample/bundle.sh
built …/TactileDemo.app (developer-id)

$ ./scripts/build-xcframework.sh
built dist/CTactile.xcframework (x86_64 arm64)
```

The check compiles the header under `-Wall -Wextra -Werror -pedantic` as C11 and
C++17, pins struct sizes/offsets (72-byte input state, 44-byte info), links the dylib,
verifies golden trigger bytes through the C entry points, checks NULL handling, and
confirms every declared function is exported.

**Samples running with a controller: pending** (TESTING.md 4.1–4.3).

## Thread-safety table

See `THREADING.md` (also summarised in the header comments).

## Assumptions to check

Sandboxed sample opens the controller with the App Store entitlements (TESTING 4.3).
