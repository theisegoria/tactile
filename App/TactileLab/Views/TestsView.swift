import SwiftUI

struct TestsView: View {
    @Bindable var session: LabSession
    @State private var selected = GuidedCheck.all[0].id
    @State private var result = ObservationResult.unverified
    @State private var notes = ""
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(check.title).font(.title2.weight(.semibold))
                    Text(check.instructions).fixedSize(horizontal: false, vertical: true)
                    if session.simulated { Label("Simulated observations are not hardware acceptance.", systemImage: "testtube.2").foregroundStyle(.orange) }
                    DurationControl(session: session)
                    if let command = check.command {
                        Button("Start This Check", systemImage: "play.fill") { session.perform(command, name: check.title, settings: check.settings, guidedID: check.id) }
                            .buttonStyle(.borderedProminent).disabled(!session.canOperate).accessibilityIdentifier("startGuidedCheck")
                    } else {
                        Button(check.id == "speaker" || check.id == "microphone" ? "Open Audio" : "Open Input") { session.tab = check.id == "speaker" || check.id == "microphone" ? .audio : .input }
                    }
                    Divider()
                    Text("Your physical observation").font(.headline)
                    Picker("Result", selection: $result) { ForEach(ObservationResult.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextEditor(text: $notes).frame(minHeight: 130).border(.separator).accessibilityLabel("Observation notes")
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
    }
}
