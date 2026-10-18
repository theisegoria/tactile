import SwiftUI
import Tactile

struct InputView: View {
    var session: LabSession
    @State private var back = false
    private var input: InputState { session.readings.input ?? InputState(kind: .bluetoothFull) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.selectedDevice?.model.uppercased() ?? "DUALSENSE EDGE")
                                .font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.5).foregroundStyle(.white.opacity(0.65))
                            HStack(spacing: 6) {
                                Circle().fill(session.readings.input == nil ? Color.gray : Color.cyan).frame(width: 5, height: 5)
                                Text(session.readings.input == nil ? "Waiting for input" : "Live input").font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Spacer()
                        Picker("Controller view", selection: $back) {
                            Text("Front").tag(false); Text("Rear").tag(true)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                    }.padding(.horizontal, 24).padding(.top, 20)
                    HStack(spacing: 20) {
                        ControllerDiagram(input: input, back: back)
                            .frame(maxWidth: .infinity).frame(height: 320)
                        VStack(spacing: 22) {
                            HStack(spacing: 22) {
                                StickPlot(title: "LEFT STICK", point: input.leftStick)
                                StickPlot(title: "RIGHT STICK", point: input.rightStick)
                            }
                            pressure("L2", value: input.l2)
                            pressure("R2", value: input.r2)
                            Text("Press a control to illuminate it")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        }.frame(width: 230).padding(.trailing, 24)
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
                .background {
                    RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.055, green: 0.07, blue: 0.105).gradient)
                        .overlay {
                            RoundedRectangle(cornerRadius: 24).fill(RadialGradient(colors: [.cyan.opacity(0.10), .clear], center: .init(x: 0.32, y: 0.45), startRadius: 0, endRadius: 300))
                        }
                }
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                .environment(\.colorScheme, .dark)
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
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width * Double(value) / 255))
                    }
            }.frame(height: 5).accessibilityLabel(name).accessibilityValue("\(value) of 255")
        }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
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

struct StickPlot: View {
    let title: String
    let point: SIMD2<UInt8>
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.white.opacity(0.03)).overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 0.7) }
                Circle().stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4])).padding(17)
                Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5)
                Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
                Circle().fill(.cyan.opacity(0.12)).frame(width: 22, height: 22)
                    .overlay { Circle().fill(.cyan).frame(width: 7, height: 7).shadow(color: .cyan.opacity(0.65), radius: 5) }
                    .offset(x: (Double(point.x) - 127.5) / 255 * 76, y: (Double(point.y) - 127.5) / 255 * 76)
            }.frame(width: 94, height: 94)
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.5))
            Text("\(point.x)  /  \(point.y)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
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
