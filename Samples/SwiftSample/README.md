# TactileDemo (Swift sample host app)

A SwiftUI app that shows live input (sticks, buttons, calibrated IMU, battery),
drives the lightbar, player LEDs and adaptive triggers, plays parametric haptics,
and demonstrates the GameController bridge.

```bash
./bundle.sh                       # Developer ID flavour, ad-hoc signed
./bundle.sh app-store             # sandboxed flavour (App Sandbox + device entitlements)
./bundle.sh developer-id "Developer ID Application: Your Name (TEAMID)"
open .build/TactileDemo.app              # same path on every toolchain
```

The first launch prompts for **Input Monitoring**; grant it in System Settings ›
Privacy & Security › Input Monitoring and relaunch.

`Support/` contains the Info.plist usage strings and both entitlement files. The
package depends on the repository root by path under the explicit name `Tactile`,
so it builds whatever the checkout directory is called.

Quitting the app (Cmd-Q or closing the window) shuts the `ControllerManager` down
first, so triggers, rumble, lightbar and LEDs return to neutral.
