import SwiftUI
import Tactile

/// First-run sheet: pairing, Input Monitoring permission and simulation mode.
///
/// Mount on the main window's root view:
/// ```swift
/// LabRootView(session: session).labOnboarding(session: session)
/// ```
/// It appears once (tracked by `OnboardingSheet.completedKey` in user
/// defaults) and never under UI tests or `--simulate` launches, so automation
/// is not blocked. Show it again from a menu with `OnboardingSheet.reset()`
/// followed by setting the binding, or present it directly.
struct OnboardingSheet: View {
    static let completedKey = "onboardingCompleted.v1"

    var session: LabSession
    var onDone: () -> Void
    @State private var page = Page.welcome

    enum Page: Int, CaseIterable { case welcome, pairing, permission, simulation }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .welcome: welcome
                case .pairing: pairing
                case .permission: permission
                case .simulation: simulation
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(28)
            .animation(.smooth(duration: 0.25), value: page)
            footer
        }
        .frame(width: 520, height: 470)
        .accessibilityIdentifier("onboardingSheet")
    }

    // MARK: Pages

    private var welcome: some View {
        step(symbol: "gamecontroller.fill", tint: .accentColor, title: "Welcome to Tactile Lab",
             text: "Explore a PS5 DualSense or DualSense Edge over Bluetooth: live input, adaptive triggers, haptics, lights and audio. Effects only run when you start them, and Stop All (⌘.) returns everything to neutral.") {
            EmptyView()
        }
    }

    private var pairing: some View {
        step(symbol: "antenna.radiowaves.left.and.right", tint: .blue, title: "Pair your controller",
             text: "Pairing happens once, in macOS Bluetooth Settings.") {
            VStack(alignment: .leading, spacing: 10) {
                numbered(1, "Make sure the controller is off (hold PS for 10 seconds if needed).")
                numbered(2, "Hold **PS** and **Create** together until the light bar flashes quickly.")
                numbered(3, "In Bluetooth Settings, choose **DualSense Wireless Controller** (or **DualSense Edge**).")
                numbered(4, "Afterwards, press PS to reconnect. Tactile Lab finds it automatically.")
                Button("Open Bluetooth Settings", systemImage: "gear") { LabSystemSettings.openBluetooth() }
                    .buttonStyle(.glass).padding(.top, 4)
            }
        }
    }

    private var permission: some View {
        step(symbol: "hand.raised.fill", tint: .yellow, title: "Allow Input Monitoring",
             text: "macOS asks before an app reads input devices. Tactile Lab needs Input Monitoring to read the controller's buttons, sticks and triggers.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol).foregroundStyle(statusColor)
                    Text("Status: \(session.simulated ? "simulated" : session.permission.rawValue)").font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboardingPermissionStatus")
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Request Access", systemImage: "hand.raised") { session.requestPermission() }
                            .buttonStyle(.glassProminent)
                            .disabled(session.permission == .granted)
                        Button("Open Settings", systemImage: "gear") { InputMonitoringPermission.openSystemSettings() }
                            .buttonStyle(.glass)
                        Button("Check Again", systemImage: "arrow.clockwise") { session.refreshPermissions() }
                            .buttonStyle(.glass)
                    }
                }
                Text("If you turn it on in System Settings, macOS may ask you to reopen Tactile Lab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var simulation: some View {
        step(symbol: "testtube.2", tint: .orange, title: "No controller? Use simulation",
             text: "Simulation mode provides virtual controllers with moving sticks and changing buttons. It sends nothing to hardware, and its observations are labelled as simulated in every export.") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Simulated controller", isOn: Binding(get: { session.simulated }, set: { enabled in Task { await session.setSimulation(enabled) } }))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("onboardingSimulation")
                Text("You can change this later under Connection Options in the toolbar.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.rawValue) { item in
                    Circle().fill(item == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page.rawValue + 1) of \(Page.allCases.count)")
            Spacer()
            if page != .welcome {
                Button("Back") { page = Page(rawValue: page.rawValue - 1) ?? .welcome }
            }
            if page == .simulation {
                Button("Get Started") { finish() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboardingDone")
            } else {
                Button("Skip") { finish() }.accessibilityIdentifier("onboardingSkip")
                Button("Continue") { page = Page(rawValue: page.rawValue + 1) ?? .simulation }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboardingContinue")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    private func step<Content: View>(symbol: String, tint: Color, title: String, text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSymbol: String {
        if session.simulated { return "testtube.2" }
        switch session.permission {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }
    private var statusColor: Color {
        if session.simulated { return .orange }
        switch session.permission {
        case .granted: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        onDone()
    }

    /// Forgets that onboarding was completed (for a Help menu "Show Welcome" item).
    static func reset() { UserDefaults.standard.removeObject(forKey: completedKey) }

    /// True when the sheet should appear automatically at launch.
    static func shouldPresentAutomatically(defaults: UserDefaults = .standard, processInfo: ProcessInfo = .processInfo) -> Bool {
        let arguments = processInfo.arguments
        if arguments.contains("--simulate") || arguments.contains("--skip-onboarding") { return false }
        if processInfo.environment["TACTILE_SIMULATED"] == "1" || processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        return !defaults.bool(forKey: completedKey)
    }
}

private struct OnboardingModifier: ViewModifier {
    var session: LabSession
    @State private var presented = false
    func body(content: Content) -> some View {
        content
            .onAppear { if OnboardingSheet.shouldPresentAutomatically() { presented = true } }
            .sheet(isPresented: $presented) { OnboardingSheet(session: session) { presented = false } }
    }
}

extension View {
    /// Presents the first-run onboarding sheet once.
    func labOnboarding(session: LabSession) -> some View { modifier(OnboardingModifier(session: session)) }
}
