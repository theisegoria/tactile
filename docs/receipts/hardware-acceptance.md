# Tactile Lab Bluetooth acceptance

Status: **deferred by the owner, 18 October 2026.** Prepare the app and automated checks now; physical DualSense Edge testing will happen later. No physical observation is inferred from simulation or transport success.

Use a DualSense Edge paired over Bluetooth. Record the macOS/app version, controller firmware, battery level and shared/exclusive mode in the exported session. Save separate WAV files alongside the report when testing experimental microphone audio.

| Check | Procedure | Current result |
|---|---|---|
| Discovery and permission | Launch with permission denied, grant access explicitly, retry and select the Bluetooth Edge. | Unverified |
| Input | Exercise every button, both sticks, L2/R2 pressure, touch contacts and motion; compare the live display to your actions. | Unverified |
| Edge controls | Exercise both Fn buttons and both rear paddles independently. | Unverified |
| Lightbar and LEDs | Start short tests, observe color/player/mute LEDs and neutral state after Stop All. | Unverified |
| Rumble | Test left/right independently at low intensity, then both; note what is physically felt. | Unverified |
| Triggers | Test each side and both with selected presets; record parameters and physical resistance. | Unverified |
| Haptics | Test parametric, audio-file and host-microphone sources; record sensation, dropouts and metrics. | Unverified |
| Reconnect | Disconnect during output, reconnect, verify neutral outputs and fresh readings before starting another test. | Unverified |
| Multiple controllers | Switch the selected device; verify readings and outputs belong only to that device. | Unverified |
| Exclusive access | Apply and reconnect; observe conflicts and restored access after quit. | Unverified |
| Experimental speaker | Start short low-volume playback; explicitly record whether sound is heard and from which route. | Unverified |
| Experimental microphone | Scan, select a hypothesis, record WAV and listen; confirm whether captured audio came from the controller. | Unverified |
| Stop and quit | Stop during output/playback/recording; quit while active; verify physical outputs neutralize and the app exits. | Unverified |

In the Tests tab choose Pass, Fail, Skipped or Unverified and add concrete observations. Export JSON and Markdown. Do not convert the table above to Pass without those physical observations. A notarization or signing pass concerns distribution trust, not controller support or experimental audio acceptance.
