import Charts
import SwiftUI
import Tactile

/// Trigger Designer: pick an effect family per trigger, edit its parameters,
/// see the library's `TriggerCurve` over travel with the live trigger
/// position, start from `TriggerPreset`s, then Apply/Test through the session.
/// Copy as Code uses `TactileCodeExport` (five languages).
struct TriggerDesignerView: View {
    @Bindable var session: LabSession
    @State private var left = TriggerDesign(spec: TriggerPreset.brakePedal.spec)
    @State private var right = TriggerDesign(spec: TriggerPreset.weaponTrigger.spec)
    @State private var presetTarget = PresetTarget.right
    @State private var showCode = false

    enum PresetTarget: String, CaseIterable { case left = "L2", right = "R2", both = "Both" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabScreenHeader(title: "Trigger Designer",
                                detail: "Shape each adaptive trigger: choose an effect, tune it and watch the curve over the trigger's travel. The curve is drawn from the parameters, not measured from the motor.") {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Copy as Code", systemImage: "chevron.left.forwardslash.chevron.right") { showCode = true }
                                .buttonStyle(.glass)
                            Button("Apply Both", systemImage: "arrow.down.to.line") { apply(left: left, right: right, name: "Trigger Designer: both") }
                                .buttonStyle(.glassProminent)
                                .disabled(!session.canOperate || left.validationMessage != nil || right.validationMessage != nil)
                                .help("Send both designs for the test length; Stop All releases them")
                                .accessibilityIdentifier("triggerApplyBoth")
                        }
                    }
                }
                NoControllerNotice(session: session)
                presetGallery
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { column(.left); column(.right) }
                    VStack(spacing: 16) { column(.left); column(.right) }
                }
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showCode) {
            CodeExportSheet(title: "Copy as Code — Triggers", code: code(in:))
        }
        .accessibilityIdentifier("triggerDesignerView")
    }

    // MARK: Presets

    private var presetGallery: some View {
        LabCard(title: "Presets", symbol: "square.grid.2x2", subtitle: "Load a starting point into the chosen trigger.") {
            Picker("Load into", selection: $presetTarget) {
                ForEach(PresetTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TriggerDesign.presets) { preset in
                    Button { load(preset.design) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(preset.id, systemImage: preset.symbol).font(.callout.weight(.medium))
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading).lineLimit(2, reservesSpace: true)
                            if !preset.preset.spec.isOfficial { LabTag(text: "Unofficial mode", symbol: "flask") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                    .accessibilityIdentifier("triggerPreset-\(preset.id)")
                }
            }
        }
    }

    private func load(_ design: TriggerDesign) {
        if presetTarget != .right { left = design }
        if presetTarget != .left { right = design }
    }

    // MARK: Columns

    private func column(_ side: TriggerSide) -> some View {
        let binding = side == .left ? $left : $right
        let design = binding.wrappedValue
        return LabCard(title: side == .left ? "L2 · left trigger" : "R2 · right trigger", symbol: side == .left ? "l2.button.angledtop.vertical.left" : "r2.button.angledtop.vertical.right",
                       subtitle: design.summary) {
            Button("Test", systemImage: "play.fill") {
                apply(left: side == .left ? design : nil, right: side == .right ? design : nil, name: "Trigger Designer: \(side == .left ? "L2" : "R2")")
            }
            .buttonStyle(.glass)
            .disabled(!session.canOperate || design.validationMessage != nil)
            .accessibilityIdentifier(side == .left ? "triggerTestLeft" : "triggerTestRight")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                TriggerCurveChart(design: design, readings: session.readings, side: side)
                    .frame(height: 170)
                TriggerParameterEditor(design: binding)
                if let effect = try? design.effect() {
                    Text(effect.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .help("The 11 bytes sent for this trigger")
                }
            }
        }
        .frame(minWidth: 320)
    }

    private func apply(left: TriggerDesign?, right: TriggerDesign?, name: String) {
        do {
            let state = OutputState(leftTrigger: try left?.effect(), rightTrigger: try right?.effect())
            session.perform(.output(state), name: name, settings: "L2=\(left?.summary ?? "unchanged"); R2=\(right?.summary ?? "unchanged")")
        } catch { session.showError(error) }
    }

    private func code(in language: CodeLanguage) -> String {
        left.code(side: .left, language: language) + "\n\n" + right.code(side: .right, language: language)
    }
}

/// The library's `TriggerCurve` for a design: resistance as an area,
/// vibration amplitude as a wavy band, the break/release point (weapon, bow)
/// as a dashed rule, and the live trigger position as a red rule.
struct TriggerCurveChart: View {
    let design: TriggerDesign
    var readings: LiveReadings
    let side: TriggerSide

    private var position: Double? {
        guard let input = readings.input else { return nil }
        return Double(side == .left ? input.l2 : input.r2) / 255
    }

    var body: some View {
        let curve = design.curve
        let points = curve.samples(count: 101)
        let vibrates = points.contains { $0.amplitude > 0 }
        Chart {
            ForEach(points, id: \.position) { p in
                AreaMark(x: .value("Travel", p.position), y: .value("Resistance", p.resistance), series: .value("Kind", "Resistance"))
                    .foregroundStyle(Color.orange.opacity(0.35).gradient)
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Travel", p.position), y: .value("Resistance", p.resistance), series: .value("Kind", "Resistance"))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.stepEnd)
            }
            if vibrates {
                ForEach(points, id: \.position) { p in
                    LineMark(x: .value("Travel", p.position), y: .value("Vibration", p.amplitude * (0.75 + 0.25 * sin(p.position * 120))),
                             series: .value("Kind", "Vibration"))
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
            if let release = curve.releasePosition {
                RuleMark(x: .value("Release", release))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let position {
                RuleMark(x: .value("Position", position))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .annotation(position: .top, alignment: .center) {
                        Text("\(Int((position * 100).rounded())) %").font(.caption2.monospacedDigit()).foregroundStyle(.red)
                    }
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1.05)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0.0, through: 1.0, by: 0.1))) { value in
                AxisGridLine()
                if let v = value.as(Double.self) { AxisValueLabel("\(Int((v * 10).rounded()))") }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) { value in
                AxisGridLine()
                if let v = value.as(Double.self) { AxisValueLabel("\(Int(v * 8))") }
            }
        }
        .chartXAxisLabel("Zone over travel (0 = released)")
        .chartYAxisLabel("Strength")
        .chartLegend(.hidden)
        .accessibilityLabel("\(side == .left ? "L2" : "R2") curve: \(design.summary)\(curve.frequency > 0 ? String(format: ", vibration %.0f Hz", curve.frequency) : "")")
    }
}
