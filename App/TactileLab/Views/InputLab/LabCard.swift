import SwiftUI

/// The glass card used by Input Lab, Profiles, Diagnostics and Tests, matching
/// the Players screen: 16 pt padding, 22 pt corners, Liquid Glass, hairline border.
struct LabCard<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    var tint: Color = .clear
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LabSectionHeader(title: title, symbol: symbol, subtitle: subtitle)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.separator.opacity(0.6), lineWidth: 1) }
    }
}

extension LabCard where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, subtitle: String? = nil, tint: Color = .clear, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, subtitle: subtitle, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// A card or page section title with an optional symbol and one-line explanation.
struct LabSectionHeader: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let symbol { Label(title, systemImage: symbol).font(.headline) } else { Text(title).font(.headline) }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A page header: large title, explanation, trailing controls. Same rhythm as Players.
struct LabPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            trailing()
        }
    }
}

/// A compact metric: caption label over a monospaced value.
struct LabMetric: View {
    let label: String
    let value: String
    var warning = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A key/value row for detail grids.
struct LabDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
