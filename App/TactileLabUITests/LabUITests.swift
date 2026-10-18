import AppKit
import XCTest

@MainActor
final class LabUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app.terminate() }

    private func launch(_ scenario: String = "connected", options: [String] = []) {
        app.launchArguments = ["--simulate", "--scenario", scenario] + options
        app.launch()
        // XCTest starts the process without the normal macOS reopen event.
        // Deliver the same event as Finder/Dock so the single Window scene opens.
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = products.appendingPathComponent("Tactile Lab.app")
        XCTAssertEqual(Bundle(url: url)?.bundleIdentifier, "dev.tactile.lab.testing")
        XCTAssertTrue(NSWorkspace.shared.open(url), "Finder-style open must succeed: \(url.path)")
        app.activate()
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["stopAll"].waitForExistence(timeout: 5))
    }

    func testTabsKeyboardNavigationAndStopAll() {
        launch()
        XCTAssertTrue(app.staticTexts["simulationBadge"].exists)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["testRumble"].waitForExistence(timeout: 5))
        app.buttons["testRumble"].click()
        XCTAssertTrue(app.staticTexts["Rumble"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["stopAll"].click()
        XCTAssertTrue(app.staticTexts["No active operation"].waitForExistence(timeout: 5))
        for key in ["1", "3", "4", "5"] { app.typeKey(key, modifierFlags: .command); XCTAssertTrue(app.buttons["stopAll"].exists) }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); screenshot.name = "Guided tests"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testDeniedAndNoDeviceScenarios() {
        launch("denied")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertFalse(app.buttons["testRumble"].isEnabled)
    }

    func testNoDeviceScenario() {
        launch("no-device")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertFalse(app.buttons["Scan for Microphone"].isEnabled)
    }

    func testOutputFailureIsShown() {
        launch("failure")
        app.typeKey("2", modifierFlags: .command)
        app.buttons["testRumble"].click()
        XCTAssertTrue(app.buttons["Dismiss"].waitForExistence(timeout: 5))
        let message = app.descendants(matching: .any)["operationError"].firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertTrue((message.value as? String ?? message.label).contains("Simulated output failure"))
    }

    func testQuitWhileOutputIsActive() {
        launch()
        app.typeKey("2", modifierFlags: .command)
        app.buttons["testRumble"].click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testQuitDuringSimulatedRecording() {
        launch()
        app.typeKey("3", modifierFlags: .command)
        let duration = app.textFields["testDuration"]
        duration.click(); duration.typeKey("a", modifierFlags: .command); duration.typeText("30\n")
        app.buttons["Record WAV…"].click()
        let save = app.dialogs.firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText("/private/tmp\n")
        save.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Microphone recording"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testScreenshotsLightNormal() {
        launch(options: ["--light"])
        captureTabs(prefix: "light-normal")
    }

    func testScreenshotsDarkMinimum() {
        launch(options: ["--dark", "--minimum-window"])
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, 880)
        captureTabs(prefix: "dark-minimum")
    }

    func testScreenshotsLightMinimum() {
        launch(options: ["--light", "--minimum-window"])
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, 880)
        captureTabs(prefix: "light-minimum")
    }

    func testScreenshotsDarkNormal() {
        launch(options: ["--dark"])
        captureTabs(prefix: "dark-normal")
    }

    func testSelectionClearsPausedReportsAndRapidOutputs() {
        launch("stale")
        app.typeKey("2", modifierFlags: .command)
        for _ in 0..<4 { app.buttons["testRumble"].click() }
        app.buttons["stopAll"].click()
        XCTAssertTrue(app.staticTexts["No active operation"].waitForExistence(timeout: 5))
        app.typeKey("4", modifierFlags: .command)
        app.buttons["Pause Display"].click()
        app.popUpButtons["selectedController"].click()
        // Native popup rows share the menuAction: AX identifier. Click the
        // queried row's center so XCTest cannot re-resolve to a different row.
        let rowFrame = app.menuItems["Simulated DualSense · ualsense"].frame
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rowFrame.midX - windowFrame.minX, dy: rowFrame.midY - windowFrame.minY)).click()
        let identity = app.descendants(matching: .any)["diagnosticIdentity"].firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "simulated-dualsense"), object: identity)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["Pause Display"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Resume Display"].exists)
        XCTAssertTrue(app.staticTexts["No active operation"].exists)
    }

    func testAboutIcon() {
        launch(options: ["--light"])
        app.menuBars.menuBarItems["Tactile Lab"].click()
        app.menuItems["About Tactile Lab"].click()
        let about = app.dialogs.firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), app.debugDescription)
        let capture = XCTAttachment(screenshot: about.screenshot())
        capture.name = "about-graphite-icon"; capture.lifetime = .keepAlways; add(capture)
    }

    private func captureTabs(prefix: String) {
        for (index, name) in ["input", "effects", "audio", "diagnostics", "tests"].enumerated() {
            app.typeKey(String(index + 1), modifierFlags: .command)
            XCTAssertTrue(app.buttons["stopAll"].isHittable)
            let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            capture.name = "\(prefix)-\(name)"; capture.lifetime = .keepAlways; add(capture)
            if index == 0 {
                app.radioButtons["Rear"].click()
                let rear = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                rear.name = "\(prefix)-rear"; rear.lifetime = .keepAlways; add(rear)
                app.radioButtons["Front"].click()
            }
        }
    }
}
