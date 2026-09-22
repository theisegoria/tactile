# Gate receipts

| Gate | Software | Hardware verification | Receipt |
|---|---|---|---|
| 0 Reconnaissance | ✅ probe built | ⏳ pending — controller not connected, no Input Monitoring | [gate-0.md](gate-0.md) |
| 1 Protocol core | ✅ 46 golden-byte tests | n/a (pure code) | [gate-1.md](gate-1.md) |
| 2 Transport, bridge, basic output | ✅ built | ⏳ pending | [gate-2.md](gate-2.md) |
| 3 Bluetooth haptics | ✅ built, software-measured | ⏳ pending (framing is 🔬) | [gate-3.md](gate-3.md) |
| 4 C ABI and samples | ✅ header check + samples build | ⏳ samples not run on hardware | [gate-4.md](gate-4.md) |
| 5 Engine bindings | ✅ written (all four, at maintainer's request) | Python tested vs dylib; others uncompiled | [gate-5.md](gate-5.md) |
| 6 Stretch research | ⏸ plan only | | [gate-6.md](gate-6.md) |
