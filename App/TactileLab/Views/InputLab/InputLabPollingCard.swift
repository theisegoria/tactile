import Charts
import SwiftUI

/// Report-interval statistics: histogram, jitter over time, percentiles, measured Hz.
struct InputLabPollingCard: View {
    let stats: PollingStats
    let reportTimes: [Double]

    private struct IntervalPoint: Identifiable { let id: Int; let ms: Double }
    private var recent: [IntervalPoint] {
        let times = Array(reportTimes.suffix(241))
        guard times.count >= 2 else { return [] }
        return zip(times.dropFirst(), times).enumerated().map { IntervalPoint(id: $0.offset, ms: ($0.element.0 - $0.element.1) * 1000) }
    }

    var body: some View {
        LabCard(title: "Report interval", symbol: "waveform.path.ecg",
                subtitle: "Arrival time between input reports. Bluetooth DualSense reports arrive at up to about 250 Hz.") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        LabMetric(label: "Measured", value: stats.intervalCount > 0 ? "\(InputLabHealthReport.number(stats.measuredHz, 1)) Hz" : "—")
                        LabMetric(label: "p50", value: ms(stats.p50Ms))
                        LabMetric(label: "p95", value: ms(stats.p95Ms))
                        LabMetric(label: "p99", value: ms(stats.p99Ms))
                    }
                    GridRow {
                        LabMetric(label: "Jitter σ", value: ms(stats.jitterMs), warning: stats.intervalCount > 10 && stats.jitterMs > InputLabHealthReport.Threshold.jitterWarningMs)
                        LabMetric(label: "Mean", value: ms(stats.meanMs))
                        LabMetric(label: "Min", value: ms(stats.minMs))
                        LabMetric(label: "Max", value: ms(stats.maxMs))
                    }
                }
                if stats.intervalCount == 0 {
                    Text("Waiting for input reports.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) { histogram; jitter }
                        VStack(alignment: .leading, spacing: 16) { histogram; jitter }
                    }
                }
            }
        }
    }

    private var histogram: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interval histogram").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart(stats.histogram) { bin in
                BarMark(x: .value("Interval (ms)", bin.midMs), y: .value("Reports", bin.count), width: .ratio(0.85))
                    .foregroundStyle(.cyan.gradient)
            }
            .chartXAxisLabel("ms")
            .frame(minWidth: 260, minHeight: 150)
            .accessibilityLabel("Report interval histogram")
            .accessibilityValue("Median \(ms(stats.p50Ms)), 99th percentile \(ms(stats.p99Ms))")
        }
    }

    private var jitter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent intervals").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart {
                ForEach(recent) { point in
                    LineMark(x: .value("Report", point.id), y: .value("Interval (ms)", point.ms))
                        .foregroundStyle(.blue).interpolationMethod(.linear)
                }
                RuleMark(y: .value("p50", stats.p50Ms)).foregroundStyle(.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("p50").font(.caption2).foregroundStyle(.green) }
                RuleMark(y: .value("p99", stats.p99Ms)).foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("p99").font(.caption2).foregroundStyle(.orange) }
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("ms")
            .frame(minWidth: 260, minHeight: 150)
            .accessibilityLabel("Recent report intervals")
            .accessibilityValue("Jitter \(ms(stats.jitterMs))")
        }
    }

    private func ms(_ value: Double) -> String { stats.intervalCount > 0 ? "\(InputLabHealthReport.number(value, 2)) ms" : "—" }
}
