import SwiftUI

/// One stick: live plot with trail, measured outline against the ideal circle,
/// recommended dead zone, and the drift and circularity numbers.
struct InputLabStickCard: View {
    let title: String
    let position: StickPoint?
    let trail: [StickPoint]
    let drift: DriftResult
    let circularity: CircularityResult
    let fromRestWindow: Bool

    var body: some View {
        LabCard(title: title, symbol: "l.joystick", subtitle: "Rotate the stick slowly against its gate for the circularity test.") {
            VStack(alignment: .leading, spacing: 14) {
                InputLabStickPlot(position: position, trail: trail, outline: circularity.outline, deadZone: drift.recommendedDeadZone)
                    .frame(maxWidth: 240)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(title) plot")
                    .accessibilityValue(position.map { String(format: "X %.2f, Y %.2f", $0.x, $0.y) } ?? "No input")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        LabMetric(label: "Resting offset", value: InputLabHealthReport.percent(drift.maxRadius),
                                  warning: drift.maxRadius > InputLabHealthReport.Threshold.driftWarning)
                        LabMetric(label: "Dead zone", value: InputLabHealthReport.percent(drift.recommendedDeadZone))
                        LabMetric(label: "Noise σ", value: InputLabHealthReport.percent(drift.noise))
                    }
                    GridRow {
                        LabMetric(label: "Circularity error", value: circularity.coverage > 0 ? "\(InputLabHealthReport.number(circularity.errorPercent, 1))%" : "—",
                                  warning: circularity.complete && circularity.errorPercent > InputLabHealthReport.Threshold.circularityWarningPercent)
                        LabMetric(label: "Rim covered", value: InputLabHealthReport.percent(circularity.coverage))
                        LabMetric(label: "Outer radius", value: circularity.coverage > 0 ? InputLabHealthReport.number(circularity.meanOuterRadius, 2) : "—")
                    }
                }
                Text(drift.sampleCount == 0 ? "No resting samples yet. Let go of the stick or use Measure Rest."
                     : "Drift from \(drift.sampleCount) \(fromRestWindow ? "rest-window" : "near-centre") samples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Canvas plot: ideal circle (dashed), measured outline (filled), dead zone, trail, live dot.
struct InputLabStickPlot: View {
    let position: StickPoint?
    let trail: [StickPoint]
    let outline: [Double?]
    let deadZone: Double

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let radius = side / 2 - 6
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func map(_ p: StickPoint) -> CGPoint { CGPoint(x: center.x + p.x * radius, y: center.y + p.y * radius) }
            let unit = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(unit, with: .color(.primary.opacity(0.04)))
            // Cross hair.
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(cross, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)
            // Measured outline.
            let sectors = outline.count
            let points: [CGPoint] = outline.enumerated().compactMap { index, r in
                guard let r else { return nil }
                let angle = (Double(index) + 0.5) / Double(sectors) * 2 * .pi
                return map(StickPoint(x: cos(angle) * r, y: sin(angle) * r))
            }
            if points.count >= 3 {
                var shape = Path(); shape.addLines(points); shape.closeSubpath()
                context.fill(shape, with: .color(.cyan.opacity(0.12)))
                context.stroke(shape, with: .color(.cyan.opacity(0.85)), lineWidth: 1.5)
            } else {
                for p in points { context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.cyan)) }
            }
            // Ideal circle on top so the deviation reads clearly.
            context.stroke(unit, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // Recommended dead zone.
            let dz = radius * deadZone
            let dead = Path(ellipseIn: CGRect(x: center.x - dz, y: center.y - dz, width: dz * 2, height: dz * 2))
            context.fill(dead, with: .color(.orange.opacity(0.12)))
            context.stroke(dead, with: .color(.orange.opacity(0.7)), lineWidth: 1)
            // Trail, fading towards the oldest sample.
            if trail.count >= 2 {
                for index in 1..<trail.count {
                    var segment = Path()
                    segment.move(to: map(trail[index - 1])); segment.addLine(to: map(trail[index]))
                    let alpha = Double(index) / Double(trail.count)
                    context.stroke(segment, with: .color(.accentColor.opacity(0.15 + 0.6 * alpha)), lineWidth: 2)
                }
            }
            if let position {
                let p = map(position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.accentColor.opacity(0.18)))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor))
            }
        }
    }
}
