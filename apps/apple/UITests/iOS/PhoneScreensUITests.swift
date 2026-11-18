import XCTest

/// Visits each iPhone screen with demo history and saves screenshots for design review.
final class PhoneScreensUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testScreens() {
        tourScreens(appearance: "light")
    }

    /// The same tour in dark mode, pinned with a launch argument (the Settings picker is
    /// covered by PhoneAppearanceUITests).
    func testScreensDark() {
        tourScreens(appearance: "dark")
    }

    private func tourScreens(appearance: String) {
        let app = launchDemoApp(extraArguments: ["-demoHistory", "-app.appearance", appearance])
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 15))
        sleep(2)  // last-session lines come from the history summaries
        attachScreenshot("\(appearance) record")

        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        sleep(2)  // let the summaries finish computing
        attachScreenshot("\(appearance) history")

        // Open the demo sailing session (other rows may be left by earlier test runs).
        let sailing = rows.containing(.staticText, identifier: "Sailing").firstMatch
        for _ in 0..<6 where !sailing.isHittable { app.swipeUp() }
        XCTAssertTrue(sailing.isHittable)
        sailing.tap()
        XCTAssertTrue(app.staticTexts["stat.Distance"].waitForExistence(timeout: 20))
        sleep(2)  // map tiles
        attachScreenshot("\(appearance) detail top")
        app.swipeUp()
        attachScreenshot("\(appearance) detail charts")
        app.swipeUp()
        attachScreenshot("\(appearance) detail laps")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Settings"].tap()
        let sailingRow = app.buttons["settings.sport.sailing"]
        XCTAssertTrue(sailingRow.waitForExistence(timeout: 10))
        attachScreenshot("\(appearance) settings")
        sailingRow.tap()
        XCTAssertTrue(app.buttons["sportSettings.speedUnit"].waitForExistence(timeout: 10))
        attachScreenshot("\(appearance) sport settings")
        app.swipeUp()
        attachScreenshot("\(appearance) sport settings lower")
    }
}

/// Regression test from the PR #26 review: History kept showing summaries computed with
/// the old auto-pause setting after it changed.
final class HistorySettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAutoPauseChangeUpdatesHistory() {
        // The demo kayak session (35 min) has a 2 min stop: auto-pause on gives 33:01
        // moving, off gives the full 35:00. The setting is changed in the app, as a user
        // would (a launch argument would pin it).
        let app = launchDemoApp(extraArguments: ["-demoHistory"])
        setKayakAutoPause(true, app)
        expectHistory(showing: "33:01", app)
        setKayakAutoPause(false, app)
        expectHistory(showing: "35:00", app)
        setKayakAutoPause(true, app)
    }

    private func setKayakAutoPause(_ on: Bool, _ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons["settings.sport.kayak"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let toggle = app.switches["sportSettings.autoPause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if (toggle.value as? String == "1") != on { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func expectHistory(showing text: String, _ app: XCUIApplication) {
        app.tabBars.buttons["History"].tap()
        let label = app.staticTexts[text]
        for _ in 0..<6 where !label.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(label.exists, "History never showed \(text)")
    }
}
