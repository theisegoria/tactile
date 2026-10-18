import SwiftUI
import Tactile

struct InputView: View {
    var session: LabSession
    @State private var back = false
    private var input: InputState { session.readings.input ?? InputState(kind: .bluetoothFull) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 10) {
                        Picker("Controller view", selection: $back) {
                            Text("Front").tag(false); Text("Back · Edge").tag(true)
                        }.pickerStyle(.segmented).frame(width: 230)
                        ControllerDiagram(input: input, back: back)
                            .frame(minWidth: 400, idealWidth: 520, maxWidth: .infinity).frame(height: 260)
                    }
                    VStack(spacing: 14) {
                        HStack(spacing: 18) {
                            StickPlot(title: "Left stick", point: input.leftStick)
                            StickPlot(title: "Right stick", point: input.rightStick)
                        }
                        pressure("L2 pressure", value: input.l2)
                        pressure("R2 pressure", value: input.r2)
                    }.frame(width: 260)
                }
                GroupBox("Named controls") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
                        ForEach(ButtonName.all) { button in
                            let active = input.buttons.contains(button.value)
                            Text(button.name).font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 7))
                                .foregroundStyle(active ? Color.accentColor : .secondary)
                                .accessibilityLabel(button.name).accessibilityValue(active ? "Pressed" : "Released")
                        }
                    }.padding(6)
                }
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Touchpad") { TouchPlot(points: input.touchPoints).frame(height: 115).padding(8) }
                    GroupBox("Calibrated motion") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let imu = session.readings.imu {
                                vector("Gyroscope", values: imu.gyroDegPerSec, unit: "°/s")
                                vector("Accelerometer", values: imu.accelG, unit: "g")
                            } else { Text("Waiting for a full input report").foregroundStyle(.secondary) }
                            Text(session.diagnostics.calibration).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                HStack {
                    Label(input.kind.rawValue, systemImage: "waveform.path.ecg")
                    Text("\(session.readings.reportCount) reports")
                    Spacer()
                    Text(session.selectedID ?? "No controller selected").textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private func pressure(_ name: String, value: UInt8) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(name); Spacer(); Text("\(value) / 255").monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: Double(value), total: 255).accessibilityLabel(name).accessibilityValue("\(value) of 255")
        }.font(.caption)
    }
    private func vector(_ label: String, values: SIMD3<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label) · \(unit)").font(.caption.weight(.medium))
            Text(String(format: "X %7.2f   Y %7.2f   Z %7.2f", values.x, values.y, values.z)).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

struct ButtonName: Identifiable {
    var id: String { name }
    let name: String
    let value: Buttons
    static let all: [ButtonName] = [
        .init(name: "Cross", value: .cross), .init(name: "Circle", value: .circle), .init(name: "Square", value: .square), .init(name: "Triangle", value: .triangle),
        .init(name: "D-pad ↑", value: .dpadUp), .init(name: "D-pad →", value: .dpadRight), .init(name: "D-pad ↓", value: .dpadDown), .init(name: "D-pad ←", value: .dpadLeft),
        .init(name: "L1", value: .l1), .init(name: "R1", value: .r1), .init(name: "L2", value: .l2), .init(name: "R2", value: .r2),
        .init(name: "L3", value: .l3), .init(name: "R3", value: .r3), .init(name: "Create", value: .create), .init(name: "Options", value: .options),
        .init(name: "PS", value: .ps), .init(name: "Touchpad", value: .touchpad), .init(name: "Mute", value: .mute),
        .init(name: "Fn left", value: .fnLeft), .init(name: "Fn right", value: .fnRight), .init(name: "Paddle L", value: .paddleLeft), .init(name: "Paddle R", value: .paddleRight)
    ]
}

struct ControllerSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.22, y: 0.12))
        p.addCurve(to: CGPoint(x: 0.08, y: 0.83), control1: CGPoint(x: 0.1, y: 0.18), control2: CGPoint(x: 0.02, y: 0.65))
        p.addCurve(to: CGPoint(x: 0.25, y: 0.85), control1: CGPoint(x: 0.12, y: 1.0), control2: CGPoint(x: 0.18, y: 1.0))
        p.addLine(to: CGPoint(x: 0.34, y: 0.65)); p.addLine(to: CGPoint(x: 0.66, y: 0.65)); p.addLine(to: CGPoint(x: 0.75, y: 0.85))
        p.addCurve(to: CGPoint(x: 0.92, y: 0.83), control1: CGPoint(x: 0.82, y: 1.0), control2: CGPoint(x: 0.88, y: 1.0))
        p.addCurve(to: CGPoint(x: 0.78, y: 0.12), control1: CGPoint(x: 0.98, y: 0.65), control2: CGPoint(x: 0.9, y: 0.18))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width, y: rect.height).translatedBy(x: rect.minX, y: rect.minY))
    }
}

struct ControllerDiagram: View {
    let input: InputState
    let back: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ControllerSilhouette().fill(.quaternary).overlay { ControllerSilhouette().stroke(.tertiary, lineWidth: 1.5) }
                if back {
                    control("Paddle L", .paddleLeft).position(at: 0.34, 0.51, in: proxy.size)
                    control("Paddle R", .paddleRight).position(at: 0.66, 0.51, in: proxy.size)
                    Text("DualSense Edge").font(.caption).foregroundStyle(.secondary).position(at: 0.5, 0.28, in: proxy.size)
                    control("Fn L", .fnLeft).position(at: 0.32, 0.72, in: proxy.size)
                    control("Fn R", .fnRight).position(at: 0.68, 0.72, in: proxy.size)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(input.buttons.contains(.touchpad) ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15))
                        .frame(width: proxy.size.width * 0.28, height: 66).overlay { Text("Touchpad").font(.caption).foregroundStyle(.secondary) }
                        .position(at: 0.5, 0.3, in: proxy.size)
                    control("↑", .dpadUp).position(at: 0.23, 0.27, in: proxy.size)
                    control("←", .dpadLeft).position(at: 0.18, 0.37, in: proxy.size)
                    control("→", .dpadRight).position(at: 0.28, 0.37, in: proxy.size)
                    control("↓", .dpadDown).position(at: 0.23, 0.47, in: proxy.size)
                    control("△", .triangle).position(at: 0.77, 0.27, in: proxy.size)
                    control("□", .square).position(at: 0.72, 0.37, in: proxy.size)
                    control("○", .circle).position(at: 0.82, 0.37, in: proxy.size)
                    control("×", .cross).position(at: 0.77, 0.47, in: proxy.size)
                    control("L3", .l3).position(at: 0.36, 0.55, in: proxy.size)
                    control("R3", .r3).position(at: 0.64, 0.55, in: proxy.size)
                    control("PS", .ps).position(at: 0.5, 0.51, in: proxy.size)
                    control("Mute", .mute).position(at: 0.5, 0.64, in: proxy.size)
                }
                control("L1", .l1).position(at: 0.22, 0.1, in: proxy.size)
                control("R1", .r1).position(at: 0.78, 0.1, in: proxy.size)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(back ? "Rear controller diagram" : "Front controller diagram")
            .accessibilityValue(ButtonName.all.filter { input.buttons.contains($0.value) }.map(\.name).joined(separator: ", "))
    }
    private func control(_ name: String, _ button: Buttons) -> some View {
        Text(name).font(.caption.weight(.semibold)).frame(minWidth: 28, minHeight: 26)
            .padding(.horizontal, name.count > 3 ? 6 : 0)
            .background(input.buttons.contains(button) ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: .capsule)
            .foregroundStyle(input.buttons.contains(button) ? Color.white : .primary)
    }
}

private extension View {
    func position(at x: Double, _ y: Double, in size: CGSize) -> some View { position(x: size.width * x, y: size.height * y) }
}

struct StickPlot: View {
    let title: String
    let point: SIMD2<UInt8>
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(.quaternary).overlay { Circle().stroke(.tertiary, lineWidth: 1) }
                Rectangle().fill(.tertiary).frame(width: 1)
                Rectangle().fill(.tertiary).frame(height: 1)
                Circle().fill(.tint).frame(width: 11, height: 11)
                    .offset(x: (Double(point.x) - 127.5) / 255 * 86, y: (Double(point.y) - 127.5) / 255 * 86)
            }.frame(width: 100, height: 100)
            Text(title).font(.caption.weight(.medium))
            Text("\(point.x), \(point.y)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue("X \(point.x), Y \(point.y)")
    }
}

struct TouchPlot: View {
    let points: [TouchPoint]
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    if point.active {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(.tint, in: .circle)
                            .position(x: 12 + min(1, Double(point.x) / 1919) * (proxy.size.width - 24),
                                      y: 12 + min(1, Double(point.y) / 1079) * (proxy.size.height - 24))
                    }
                }
                if !points.contains(where: \.active) { Text("No contacts").font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Touchpad contacts")
            .accessibilityValue(points.filter(\.active).map { "ID \($0.id), X \($0.x), Y \($0.y)" }.joined(separator: "; "))
    }
}
