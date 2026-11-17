import XCTest

/// Visits each iPhone screen with demo history and saves screenshots for design review.
final class PhoneScreensUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testScreens() {
        let app = launchDemoApp(extraArguments: ["-demoHistory", "-recorder.sport", "sailing"])
        XCTAssertTrue(app.buttons["control.start"].waitForExistence(timeout: 15))
        attachScreenshot("record")

        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        sleep(2)  // let the summaries finish computing
        attachScreenshot("history")

        // Open the demo sailing session (other rows may be left by earlier test runs).
        let sailing = rows.containing(.staticText, identifier: "Sailing").firstMatch
        for _ in 0..<6 where !sailing.isHittable { app.swipeUp() }
        XCTAssertTrue(sailing.isHittable)
        sailing.tap()
        XCTAssertTrue(app.staticTexts["stat.Distance"].waitForExistence(timeout: 20))
        sleep(2)  // map tiles
        attachScreenshot("detail top")
        app.swipeUp()
        attachScreenshot("detail charts")
        app.swipeUp()
        attachScreenshot("detail laps")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Units"].waitForExistence(timeout: 10))
        attachScreenshot("settings")
    }
}
