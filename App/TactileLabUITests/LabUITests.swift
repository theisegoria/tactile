import XCTest

@MainActor
final class LabUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app.terminate() }

    private func launch(_ scenario: String = "connected", options: [String] = []) {
        app.launchArguments = ["--simulate", "--scenario", scenario, "-ApplePersistenceIgnoreState", "YES"] + options
        app.launch()
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
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Guided tests"; screenshot.lifetime = .keepAlways; add(screenshot)
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Simulated output failure' ")).firstMatch.exists)
    }

    func testQuitWhileOutputIsActive() {
        launch()
        app.typeKey("2", modifierFlags: .command)
        app.buttons["testRumble"].click()
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
