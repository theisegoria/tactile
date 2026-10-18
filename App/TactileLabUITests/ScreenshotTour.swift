import AppKit
import XCTest

/// Captures every tab of the simulated app as test attachments for UI review
/// (scripts/lab-screenshots.sh exports them as PNGs). Skipped unless
/// TACTILE_SCREENSHOT_TOUR=1 (pass TEST_RUNNER_TACTILE_SCREENSHOT_TOUR=1 to
/// xcodebuild). Simulation only: no controller output.
@MainActor
final class ScreenshotTour: XCTestCase {
    func testScreenshotTour() throws {
        guard ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_TOUR"] == "1" else {
            throw XCTSkip("Set TACTILE_SCREENSHOT_TOUR=1 to capture the tour")
        }
        let scenario = ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_SCENARIO"] ?? "multiple"
        let appearance = ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_APPEARANCE"] ?? "light"

        let app = XCUIApplication()
        let extra = ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_ARGS"]?.split(separator: " ").map(String.init) ?? []
        app.launchArguments = ["--simulate", "--scenario", scenario, "--\(appearance)"] + extra
        app.launch()
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open(products.appendingPathComponent("Tactile Lab.app"))
        app.activate()
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        defer { app.terminate() }

        func capture(_ name: String) {
            // Park the pointer beside the window so it is not in the shot
            // (XCUICoordinate.hover cannot leave the window).
            let frame = app.windows.firstMatch.frame
            // A click on the static status bar dismisses any transient overlay
            // (input-source or focus indicators) XCTest's typing can leave.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.985)).click()
            app.typeKey(.escape, modifierFlags: [])
            CGWarpMouseCursorPosition(CGPoint(x: max(frame.minX - 60, 2), y: frame.midY))
            if ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_DEBUG"] == "1" {
                print("TOUR window=\(frame) mouse=\(NSEvent.mouseLocation)")
                let hits = app.descendants(matching: .any).allElementsBoundByIndex.filter {
                    let f = $0.frame
                    return f.width < 60 && f.height < 60 && f.contains(CGPoint(x: frame.minX + 338, y: frame.minY + 464))
                }
                for h in hits { print("TOUR hit: \(h.elementType.rawValue) id=\(h.identifier) label=\(h.label) frame=\(h.frame)") }
            }
            // macOS shows an input-source indicator beside the caret whenever a
            // text field takes focus (the Tests notes field does on tab
            // switch); it fades after about two seconds.
            sleep(3)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "\(appearance)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let tabs = ProcessInfo.processInfo.environment["TACTILE_SCREENSHOT_TABS"]?.split(separator: ",").map(String.init)
            ?? ["6", "1", "2", "3", "4", "5"]
        for key in tabs {
            app.typeKey(Character(key).description, modifierFlags: .command)
            capture("tab\(key)")
        }
    }
}
