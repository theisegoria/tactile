import SwiftUI

struct TestsView: View {
    @Bindable var session: LabSession
    @State private var selected = GuidedCheck.all[0].id
    @State private var result = ObservationResult.unverified
    @State private var notes = ""
    private enum Focus: Hashable { case checks, notes }
    @FocusState private var focus: Focus?
    private var check: GuidedCheck { GuidedCheck.all.first { $0.id == selected } ?? GuidedCheck.all[0] }
    private var observation: GuidedObservation? { session.observations.first { $0.id == selected } }
    private var completed: Int { session.observations.filter { $0.result != .unverified }.count }

    var body: some View {
        HSplitView {
            List(GuidedCheck.all, selection: $selected) { item in
                let state = session.observations.first { $0.id == item.id }?.result ?? .unverified
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(state)).foregroundStyle(Self.color(state)).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).lineLimit(2)
                        Text(state.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4).tag(item.id)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Guided checks").font(.headline)
                    Spacer()
                    Text("\(completed) of \(GuidedCheck.all.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .focused($focus, equals: .checks)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabPageHeader(title: check.title, subtitle: check.settings) {
                        statusBadge(observation?.result ?? .unverified)
                    }
                    if let kind = LabEmptyState.kind(for: session) {
                        LabEmptyStateView(kind: kind, session: session)
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                    LabCard(title: "Instructions", symbol: "list.number") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(check.instructions).fixedSize(horizontal: false, vertical: true)
                            if session.simulated {
                                Label("Simulated observations are not hardware acceptance.", systemImage: "testtube.2").foregroundStyle(.orange)
                            }
                            Label("Output checks run for the test length set in the header (\(session.duration.formatted()) s).", systemImage: "timer")
                                .font(.callout).foregroundStyle(.secondary)
                            if let command = check.command {
                                Button("Start This Check", systemImage: "play.fill") { session.perform(command, name: check.title, settings: check.settings, guidedID: check.id) }
                                    .buttonStyle(.glassProminent).disabled(!session.canOperate).accessibilityIdentifier("startGuidedCheck")
                            } else {
                                Button(check.id == "speaker" || check.id == "microphone" ? "Open Audio" : "Open Input") {
                                    session.tab = check.id == "speaker" || check.id == "microphone" ? .audio : .input
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    LabCard(title: "Your physical observation", symbol: "eye",
                            subtitle: "A successful HID request does not automatically mark this check as passed.") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Result", selection: $result) { ForEach(ObservationResult.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                            TextEditor(text: $notes)
                                .focused($focus, equals: .notes)
                                .writingToolsBehavior(.disabled)
                                .font(.body).scrollContentBackground(.hidden).padding(6)
                                .frame(minHeight: 130)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                                .overlay(alignment: .topLeading) {
                                    if notes.isEmpty {
                                        Text("What did you see, feel or hear?").foregroundStyle(.tertiary)
                                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                                    }
                                }
                                .accessibilityLabel("Observation notes")
                            HStack {
                                if let observedAt = observation?.observedAt {
                                    Text("Saved \(observedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Save Observation") { session.observe(check.id, result: result, notes: notes) }
                                    .buttonStyle(.glassProminent)
                                    .disabled(session.selectedID == nil).accessibilityIdentifier("saveObservation")
                            }
                        }
                    }
                    LabCard(title: "Report", symbol: "doc.richtext", subtitle: "Session JSON and a Markdown summary with every observation and operation.") {
                        Button("Export JSON and Markdown…", systemImage: "square.and.arrow.up") { session.exportReport() }
                            .buttonStyle(.glass)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }.frame(minWidth: 480)
        }.onChange(of: selected, initial: true) { _, id in
            let observation = session.observations.first { $0.id == id }
            result = observation?.result ?? .unverified; notes = observation?.notes ?? ""
        }.onChange(of: session.selectedID) { _, _ in
            let observation = session.observations.first { $0.id == selected }
            result = observation?.result ?? .unverified; notes = observation?.notes ?? ""
        }
        // Arrive with the list of checks focused (arrow keys move between
        // checks), not with a caret in the notes editor, which would take
        // typing focus and show the input-source indicator over the page.
        .defaultFocus($focus, .checks)
        .onAppear { DispatchQueue.main.async { focus = .checks } }
    }

    private func statusBadge(_ state: ObservationResult) -> some View {
        Label(state.rawValue, systemImage: Self.symbol(state))
            .font(.callout.weight(.medium))
            .foregroundStyle(Self.color(state))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.tint(Self.color(state).opacity(0.15)), in: .capsule)
    }

    static func symbol(_ state: ObservationResult) -> String {
        switch state {
        case .unverified: "circle.dashed"
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        }
    }

    static func color(_ state: ObservationResult) -> Color {
        switch state {
        case .unverified: .secondary
        case .pass: .green
        case .fail: .red
        case .skipped: .orange
        }
    }
}
