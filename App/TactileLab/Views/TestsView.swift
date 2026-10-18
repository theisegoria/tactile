import SwiftUI

struct TestsView: View {
    @Bindable var session: LabSession
    @State private var selected = GuidedCheck.all[0].id
    @State private var result = ObservationResult.unverified
    @State private var notes = ""
    private enum Focus: Hashable { case checks, notes }
    @FocusState private var focus: Focus?
    private var check: GuidedCheck { GuidedCheck.all.first { $0.id == selected } ?? GuidedCheck.all[0] }

    var body: some View {
        HSplitView {
            List(GuidedCheck.all, selection: $selected) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title)
                        Text(session.observations.first { $0.id == item.id }?.result.rawValue ?? "Unverified").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 4).tag(item.id)
            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                .focused($focus, equals: .checks)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(check.title).font(.title2.weight(.semibold))
                    Text(check.instructions).fixedSize(horizontal: false, vertical: true)
                    if session.simulated { Label("Simulated observations are not hardware acceptance.", systemImage: "testtube.2").foregroundStyle(.orange) }
                    Label("Output checks run for the test length set in the header (\(session.duration.formatted()) s).", systemImage: "timer").font(.callout).foregroundStyle(.secondary)
                    if let command = check.command {
                        Button("Start This Check", systemImage: "play.fill") { session.perform(command, name: check.title, settings: check.settings, guidedID: check.id) }
                            .buttonStyle(.borderedProminent).disabled(!session.canOperate).accessibilityIdentifier("startGuidedCheck")
                    } else {
                        Button(check.id == "speaker" || check.id == "microphone" ? "Open Audio" : "Open Input") { session.tab = check.id == "speaker" || check.id == "microphone" ? .audio : .input }
                    }
                    Divider()
                    Text("Your physical observation").font(.headline)
                    Picker("Result", selection: $result) { ForEach(ObservationResult.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextEditor(text: $notes)
                        .focused($focus, equals: .notes)
                        .writingToolsBehavior(.disabled)
                        .font(.body).scrollContentBackground(.hidden).padding(6)
                        .frame(minHeight: 130)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty {
                                Text("What did you see, feel or hear?").foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Observation notes")
                    Text("Describe what you saw, felt or heard. A successful HID request does not automatically mark this check as passed.").font(.caption).foregroundStyle(.secondary)
                    Button("Save Observation") { session.observe(check.id, result: result, notes: notes) }.disabled(session.selectedID == nil).accessibilityIdentifier("saveObservation")
                    Divider()
                    Button("Export JSON and Markdown…", systemImage: "square.and.arrow.up") { session.exportReport() }
                }.padding(24)
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
}
