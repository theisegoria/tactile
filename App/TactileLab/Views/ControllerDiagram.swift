import SwiftUI
import Tactile

/// Normalized landmarks are aligned to the original, transparent artwork.
/// Keeping its aspect ratio intact avoids stretching the controller on resize.
struct ControllerDiagram: View {
    let input: InputState
    let back: Bool
    private let signal = Color(red: 0.13, green: 0.89, blue: 1)

    var body: some View {
        Image(back ? "ControllerRear" : "ControllerFront")
            .resizable().aspectRatio(1.5, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack {
                        if back {
                            highlight(.paddleLeft, x: 0.65, y: 0.49, width: 0.08, height: 0.14, in: size)
                            highlight(.paddleRight, x: 0.35, y: 0.49, width: 0.08, height: 0.14, in: size)
                        } else {
                            highlight(.dpadUp, x: 0.199, y: 0.246, width: 0.047, height: 0.07, in: size)
                            highlight(.dpadDown, x: 0.199, y: 0.383, width: 0.047, height: 0.07, in: size)
                            highlight(.dpadLeft, x: 0.148, y: 0.315, width: 0.05, height: 0.065, in: size)
                            highlight(.dpadRight, x: 0.25, y: 0.315, width: 0.05, height: 0.065, in: size)
                            highlight(.triangle, x: 0.799, y: 0.217, width: 0.055, height: 0.083, in: size)
                            highlight(.circle, x: 0.865, y: 0.313, width: 0.055, height: 0.083, in: size)
                            highlight(.cross, x: 0.799, y: 0.409, width: 0.055, height: 0.083, in: size)
                            highlight(.square, x: 0.734, y: 0.313, width: 0.055, height: 0.083, in: size)
                            highlight(.create, x: 0.278, y: 0.169, width: 0.024, height: 0.058, in: size)
                            highlight(.options, x: 0.722, y: 0.169, width: 0.024, height: 0.058, in: size)
                            highlight(.ps, x: 0.5, y: 0.476, width: 0.055, height: 0.065, in: size)
                            highlight(.mute, x: 0.5, y: 0.548, width: 0.038, height: 0.016, in: size)
                            highlight(.fnLeft, x: 0.347, y: 0.648, width: 0.053, height: 0.045, in: size)
                            highlight(.fnRight, x: 0.653, y: 0.648, width: 0.053, height: 0.045, in: size)
                            highlight(.touchpad, x: 0.5, y: 0.227, width: 0.32, height: 0.24, in: size)
                            stick(input.leftStick, pressed: input.buttons.contains(.l3), x: 0.339, y: 0.503, in: size)
                            stick(input.rightStick, pressed: input.buttons.contains(.r3), x: 0.663, y: 0.503, in: size)
                            ForEach(Array(input.touchPoints.enumerated()), id: \.offset) { _, point in
                                if point.active {
                                    Circle().fill(signal).frame(width: 7, height: 7)
                                        .shadow(color: signal, radius: 6)
                                        .position(x: (0.34 + min(1, Double(point.x) / 1919) * 0.32) * size.width,
                                                  y: (0.13 + min(1, Double(point.y) / 1079) * 0.18) * size.height)
                                }
                            }
                        }
                        if !back {
                            highlight(.l1, x: 0.205, y: 0.084, width: 0.11, height: 0.045, in: size)
                            highlight(.r1, x: 0.795, y: 0.084, width: 0.11, height: 0.045, in: size)
                        }
                        trigger(input.l2, x: back ? 0.795 : 0.205, in: size)
                        trigger(input.r2, x: back ? 0.205 : 0.795, in: size)
                    }
                }.allowsHitTesting(false)
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(back ? "Rear DualSense Edge controller, live input" : "Front DualSense Edge controller, live input")
            .accessibilityValue(ButtonName.all.filter { input.buttons.contains($0.value) }.map(\.name).joined(separator: ", "))
    }

    private func highlight(_ button: Buttons, x: Double, y: Double, width: Double, height: Double, in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: min(width * size.width, height * size.height) * 0.4)
            .fill(signal.opacity(0.24))
            .overlay { RoundedRectangle(cornerRadius: min(width * size.width, height * size.height) * 0.4).stroke(signal, lineWidth: 1.5) }
            .shadow(color: signal.opacity(0.7), radius: 7)
            .frame(width: size.width * width, height: size.height * height)
            .opacity(input.buttons.contains(button) ? 1 : 0)
            .position(x: size.width * x, y: size.height * y)
    }

    private func stick(_ point: SIMD2<UInt8>, pressed: Bool, x: Double, y: Double, in size: CGSize) -> some View {
        let dx = (Double(point.x) - 127.5) / 127.5
        let dy = (Double(point.y) - 127.5) / 127.5
        return ZStack {
            Circle().stroke(signal.opacity(pressed ? 1 : 0.30), lineWidth: pressed ? 2 : 0.8)
                .frame(width: size.width * 0.12, height: size.width * 0.12)
            Circle().fill(signal).frame(width: 5, height: 5)
                .shadow(color: signal, radius: 4)
                .offset(x: dx * size.width * 0.041, y: dy * size.width * 0.041)
                .opacity(abs(dx) > 0.04 || abs(dy) > 0.04 || pressed ? 1 : 0)
        }.position(x: size.width * x, y: size.height * y)
    }

    private func trigger(_ value: UInt8, x: Double, in size: CGSize) -> some View {
        Capsule().fill(signal).frame(width: size.width * 0.10 * Double(value) / 255, height: 3)
            .shadow(color: signal, radius: 5)
            .position(x: size.width * x, y: size.height * 0.05)
    }
}

#Preview("Live controller") {
    ControllerDiagram(input: Simulation.snapshot(tick: 23).input!, back: false)
        .padding(28).background(Color(red: 0.055, green: 0.07, blue: 0.105)).frame(width: 700)
}
