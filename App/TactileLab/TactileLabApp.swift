import AppKit
import SwiftUI

@main
struct TactileLabApp: App {
    @NSApplicationDelegateAdaptor(LabAppDelegate.self) private var delegate
    @State private var session = LabSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Tactile Lab", id: "lab") {
            LabRootView(session: session)
                .frame(minWidth: 860, minHeight: 660)
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : (ProcessInfo.processInfo.arguments.contains("--light") ? .light : nil))
                .task { delegate.session = session; await session.start() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { session.refreshPermissions() } }
        }
        .keyboardShortcut("0", modifiers: .command)
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--minimum-window") ? 860 : 1060,
                     height: ProcessInfo.processInfo.arguments.contains("--minimum-window") ? 660 : 790)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(ProcessInfo.processInfo.arguments.contains("--simulate") ? .disabled : .automatic)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Export Session…") { session.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Controller") {
                Button("Stop All") { Task { await session.stopAll() } }.keyboardShortcut(".", modifiers: .command)
                Button("Retry Connection") { Task { await session.reconnect() } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(LabTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    Button(tab.rawValue) { session.tab = tab }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
    }
}

/// Two independent tasks race to reply. No task-group scope can hold Cmd-Q
/// open while an uncooperative driver request is still finishing.
@MainActor
final class LabAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: LabSession?
    private var terminating = false
    private var replied = false
    private var cleanup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        cleanup = Task { await session?.shutdown(); finish(sender) }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            cleanup?.cancel()
            finish(sender)
        }
        return .terminateLater
    }
    private func finish(_ sender: NSApplication) {
        guard !replied else { return }
        replied = true
        deadline?.cancel()
        sender.reply(toApplicationShouldTerminate: true)
    }
}
