import XCTest

/// Records a demo kayak session on the iPhone: live metrics, pause and resume, lap, stop.
final class PhoneSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoSession() {
        // `-recorder.sport kayak` sets the remembered sport for this launch only.
        let app = launchDemoApp(extraArguments: ["-recorder.sport", "kayak"])

        let start = app.buttons["control.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        attachScreenshot("1 home")
        start.tap()

        let speed = app.staticTexts["metric.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForLabel(speed, "9.0 km/h")
        XCTAssertTrue(app.staticTexts["metric.distance"].exists)
        attachScreenshot("2 recording")

        // The Live Activity: leave the app and look at the Dynamic Island and Lock Screen.
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        _ = springboard.wait(for: .runningForeground, timeout: 5)
        sleep(6)  // let an update with live numbers arrive
        attachScreenshot("2b live activity")
        app.activate()
        XCTAssertTrue(speed.waitForExistence(timeout: 10))

        app.buttons["control.pause"].tap()
        XCTAssertTrue(app.staticTexts["pauseBadge"].waitForExistence(timeout: 10))
        attachScreenshot("3 paused")
        app.buttons["control.pause"].tap()
        XCTAssertTrue(app.staticTexts["pauseBadge"].waitForNonExistence(timeout: 10))
        app.buttons["control.lap"].tap()
        waitForLabel(app.staticTexts["metric.lap"], "Lap 2")
        attachScreenshot("4 lap")

        app.buttons["control.stop"].tap()
        let confirm = app.buttons["End session"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        attachScreenshot("5 stopped")
    }
}
