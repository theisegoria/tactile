import AppKit
import SwiftUI

/// The glass card used by the Composer, Trigger Designer, Speaker and Effects
/// screens: the same 16 pt padding and 22 pt corner radius as the Players
/// cards, a header with a symbol, title, optional subtitle and accessory.
struct LabCard<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    var tint: Color = .clear
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 22))
    }
}

extension LabCard where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, subtitle: String? = nil, tint: Color = .clear, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, subtitle: subtitle, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// Screen header matching the Players screen: title, explanation, trailing controls.
struct LabScreenHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            trailing
        }
    }
}

extension LabScreenHeader where Trailing == EmptyView {
    init(title: String, detail: String) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// Explains why outputs are disabled when no controller is selected.
struct NoControllerNotice: View {
    var session: LabSession
    var body: some View {
        if !session.canOperate {
            Label(session.selectedDevice == nil ? "Select a connected controller in the toolbar to send outputs. You can still edit and preview here."
                  : session.selectedDevice?.connected == false ? "The selected controller is offline. Outputs are disabled until it reconnects."
                  : "Connecting… outputs are enabled once the controller is ready.",
                  systemImage: "gamecontroller")
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.yellow.opacity(0.12)), in: .rect(cornerRadius: 16))
        }
    }
}

/// A small capsule label such as "Unverified on hardware".
struct LabTag: View {
    let text: String
    var symbol: String = "questionmark.diamond"
    var tint: Color = .orange
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: .capsule)
    }
}

/// Shows generated source with Copy, for "Copy as code".
struct CodeExportSheet: View {
    let title: String
    let code: String
    var planned: [String] = []
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if !planned.isEmpty {
                    Text("Coming from the library: \(planned.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(code).font(.body.monospaced()).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 480)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640)
    }
}
