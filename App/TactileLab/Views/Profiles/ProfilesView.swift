import AppKit
import SwiftUI
import Tactile
import UniformTypeIdentifiers

/// Profiles: named sets of lightbar, player LEDs, trigger effects and haptic
/// gain, per game or per player. Apply, rename, duplicate, delete, import, export.
///
/// Mount as a detail screen: `ProfilesView(session: session)`.
struct ProfilesView: View {
    var session: LabSession
    var store: LabProfileStore
    @State private var editing: EditRequest?
    @State private var renaming: LabProfile?
    @State private var newName = ""
    @State private var deleting: LabProfile?
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]

    private struct EditRequest: Identifiable {
        let id = UUID()
        var profile: LabProfile
        var isNew: Bool
    }

    init(session: LabSession, store: LabProfileStore? = nil) {
        self.session = session
        self.store = store ?? .shared
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabPageHeader(title: "Profiles",
                              subtitle: "Save lights, triggers and haptic gain per game or per player. Lights and triggers run for the test length; the active profile's haptic gain scales every haptic the Lab sends.") {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("New Profile", systemImage: "plus") { editing = EditRequest(profile: LabProfile(name: store.uniqueName("New profile")), isNew: true) }
                                .buttonStyle(.glassProminent)
                                .accessibilityIdentifier("newProfile")
                            Menu {
                                Button("Import Profiles…", systemImage: "square.and.arrow.down") { importProfiles() }
                                Button("Export All Profiles…", systemImage: "square.and.arrow.up") { export(nil, suggested: "Tactile Lab profiles.json") }
                                    .disabled(store.profiles.isEmpty)
                                Divider()
                                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                                    .disabled(store.profiles.isEmpty)
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .menuStyle(.button).buttonStyle(.glass).fixedSize()
                            .accessibilityIdentifier("profilesMore")
                        }
                    }
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .padding(12).glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
                }
                if session.simulated {
                    Label("Simulated session: applying a profile sends nothing to a controller.", systemImage: "testtube.2")
                        .font(.callout).foregroundStyle(.orange)
                }
                if store.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles Yet", systemImage: "person.crop.rectangle.stack")
                    } description: {
                        Text("Create a profile for a game or a player, or import one that was exported from Tactile Lab.")
                    } actions: {
                        HStack {
                            Button("New Profile") { editing = EditRequest(profile: LabProfile(name: "New profile"), isNew: true) }.buttonStyle(.glassProminent)
                            Button("Import…") { importProfiles() }.buttonStyle(.glass)
                        }
                    }
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.profiles) { profile in card(profile) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("profilesView")
        .sheet(item: $editing) { request in
            ProfileEditorSheet(profile: request.profile, title: request.isNew ? "New Profile" : "Edit Profile",
                               onSave: { profile in if request.isNew { store.add(profile) } else { store.update(profile) } },
                               onTry: { profile in tryProfile(profile) })
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { store.rename(renaming.id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) { if let deleting { store.delete([deleting.id]) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The profile is removed from Tactile Lab. Export it first if you want a copy.")
        }
    }

    private func card(_ profile: LabProfile) -> some View {
        let active = profile.id == store.activeID
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(Color(profile.lightbar).gradient)
                    .frame(width: 38, height: 38)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25)) }
                    .accessibilityLabel("Lightbar colour #\(profile.lightbar.hex)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Label(profile.scope.label, systemImage: profile.scope.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if active {
                    Text("Active").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.35)), in: .capsule)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Player LEDs", profile.playerLEDs == 0 ? "Off" : "\(profile.playerLEDs)")
                row("L2", profile.leftTrigger.summary)
                row("R2", profile.rightTrigger.summary)
                row("Haptic gain", String(format: "%.2f", profile.hapticGain))
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button("Apply", systemImage: "play.fill") { store.apply(profile, to: session) }
                    .buttonStyle(.glassProminent)
                    .disabled(!session.canOperate)
                    .accessibilityIdentifier("applyProfile")
                Button("Edit", systemImage: "slider.horizontal.3") { editing = EditRequest(profile: profile, isNew: false) }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Menu {
                    Button("Rename…") { newName = profile.name; renaming = profile }
                    Button("Duplicate") { store.duplicate(profile.id) }
                    Button("Export…") { export([profile.id], suggested: "\(profile.name).json") }
                    Button("Export as .tactileprofile…") { exportLibrary(profile) }
                        .help("The library's ControllerProfile format, for the C ABI, the bindings or another app. Scope and mute LED are Lab-only and not included.")
                    Divider()
                    Button(active ? "Clear Active" : "Mark Active") { store.setActive(active ? nil : profile.id) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = profile }
                } label: {
                    Label("Profile actions", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).labelStyle(.iconOnly).fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(Color(profile.lightbar).opacity(active ? 0.16 : 0.06)), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(active ? AnyShapeStyle(Color(profile.lightbar).opacity(0.8)) : AnyShapeStyle(.separator), lineWidth: active ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileCard-\(profile.name)")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func tryProfile(_ profile: LabProfile) {
        guard profile.problems.isEmpty else { return }
        session.perform(.output(profile.outputState), name: "Try profile: \(profile.name)", settings: profile.summary)
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, Self.libraryType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Tactile Lab profile exports (.json) or Tactile profiles (.tactileprofile)."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try store.importProfiles(from: url) } catch { session.showError(error) }
        }
    }

    private func export(_ ids: Set<String>?, suggested: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggested.replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(ids, to: url) } catch { session.showError(error) }
    }

    static let libraryType = UTType(filenameExtension: ControllerProfile.fileExtension, conformingTo: .json) ?? .json

    private func exportLibrary(_ profile: LabProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.libraryType]
        panel.nameFieldStringValue = "\(profile.name).\(ControllerProfile.fileExtension)".replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try profile.controllerProfile.encoded().write(to: url, options: .atomic) } catch { session.showError(error) }
    }
}
