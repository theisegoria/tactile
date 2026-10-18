import Foundation
import Tactile

struct GuidedCheck: Identifiable {
    let id: String
    let title: String
    let instructions: String
    let command: LabCommand?
    let settings: String

    static let all: [GuidedCheck] = [
        .init(id: "input", title: "Buttons, sticks and triggers", instructions: "Open Input. Press each named button, move both sticks through their range, and squeeze each trigger. Confirm the diagram follows the physical control and returns to rest.", command: nil, settings: "Input observation only"),
        .init(id: "edge", title: "Edge paddles and Fn buttons", instructions: "Press each rear paddle and each Fn button independently. Confirm the named indicators match the physical controls. Record any profile-dependent mapping.", command: nil, settings: "Edge mapping observation; bit order requires hardware confirmation"),
        .init(id: "touch-imu", title: "Touchpad and calibrated motion", instructions: "Move one then two fingers on the touchpad. Rotate and tilt the controller. Check contact positions and motion units in Input; note drift while resting flat.", command: nil, settings: "Touch and calibrated IMU observation"),
        .init(id: "lights", title: "Lightbar and LEDs", instructions: "Start the check and confirm a cyan lightbar, player 2 indicator, and illuminated mute LED. They should reset when the duration ends or Stop All is pressed.", command: .output(OutputState(lightbar: LightbarColor(red: 0, green: 140, blue: 220), playerLEDs: .player(2), muteLED: .on)), settings: "Lightbar RGB 0/140/220; player 2; mute LED on"),
        .init(id: "triggers", title: "Adaptive trigger resistance", instructions: "Start the check and gently squeeze each trigger. Confirm resistance begins near zone 3 and stops at the end of the check. A successful write alone is not a pass.", command: .output(OutputState(leftTrigger: try! .feedback(position: 3, strength: 4), rightTrigger: try! .feedback(position: 3, strength: 4))), settings: "Both triggers: feedback position 3, strength 4"),
        .init(id: "rumble", title: "Independent rumble", instructions: "Start this left-actuator check. Then use Effects to test the right actuator separately. Confirm the physical side and that Stop All ends vibration.", command: .output(OutputState(rumble: Rumble(left: 100, right: 0))), settings: "Legacy rumble left 100, right 0"),
        .init(id: "haptics", title: "Parametric haptics", instructions: "Start the check while holding the controller. Confirm a low-level tone in both grips. Note missing channels, distortion, latency or interruptions.", command: .haptic(.tone(intensity: 0.25, frequency: 160, duration: 60), .both), settings: "Both actuators; 160 Hz; intensity 0.25; bounded by test duration"),
        .init(id: "reconnect", title: "Disconnect and reconnect", instructions: "Start a short effect in Effects, then turn the controller off and reconnect over Bluetooth. Confirm old readings clear, the same identity returns, and no effect resumes automatically. Select another controller if available and check that inputs never mix.", command: nil, settings: "Bluetooth-only; neutral output on reconnect"),
        .init(id: "speaker", title: "Experimental speaker playback", instructions: "In Audio, choose a short audio file, inspect framing and explicitly start playback. Record whether sound is actually heard, its route, level and quality. Leave Unverified when transmission succeeds without audible evidence.", command: nil, settings: "Experimental speaker/audio routing; configure in Audio"),
        .init(id: "microphone", title: "Experimental controller microphone", instructions: "In Audio, start a scan while speaking near the controller. Select a candidate, record a WAV, and listen to that file. Record whether it contains the controller microphone. Candidate scoring or decoded frames alone do not establish a working microphone.", command: nil, settings: "Experimental uplink scan and WAV recording")
    ]
}
