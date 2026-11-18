import XCTest

/// The iPhone's sport cards and per-sport settings, which match the watch's.
final class PhoneSportCardsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Set a countdown and first screen from a card's gear, then start: countdown with
    /// Sync (sailing) → the session opens on distance.
    func testCardSettingsCountdownAndStart() {
        let app = launchDemoApp()
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        attachScreenshot("cards")

        app.buttons["sportSettings.open.sailing"].tap()
        let countdown = app.buttons["sportSettings.countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        attachScreenshot("card settings sheet")
        choose("1 min", from: countdown, app)
        choose("Distance", from: app.buttons["sportSettings.firstScreen"], app)
        app.buttons["sportSettings.done"].tap()

        XCTAssertTrue(sailing.waitForExistence(timeout: 10))
        XCTAssertTrue(sailing.label.contains("Sailing"))
        attachScreenshot("cards with countdown")
        sailing.tap()

        let time = element("countdown.time", in: app)
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        sleep(2)
        attachScreenshot("countdown")
        app.buttons["countdown.sync"].tap()
        // 0:57 or so rounds to 1:00.
        XCTAssertTrue(["60 seconds to start", "59 seconds to start"].contains(time.label), "after sync: \(time.label)")
        app.buttons["countdown.startNow"].tap()

        let distance = element("metric.distance", in: app)
        XCTAssertTrue(distance.waitForExistence(timeout: 15))
        XCTAssertEqual(distance.label, "Distance")
        let speed = element("metric.speed", in: app)
        waitForMetricValue(speed, "4.9 knots")
        XCTAssertLessThan(distance.frame.maxY, speed.frame.minY)
        attachScreenshot("live distance first")

        endSession(app)
        XCTAssertTrue(sailing.waitForExistence(timeout: 20))
    }

    /// Swiping a sport row offers Hide; it leaves the list, and Undo brings it back.
    func testSwipeHidesSport() {
        let app = launchDemoApp()
        let canoe = app.buttons["sport.canoe"]
        XCTAssertTrue(canoe.waitForExistence(timeout: 15))
        canoe.swipeLeft()
        let hide = app.buttons["sport.hide.canoe"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        attachScreenshot("swipe to hide")
        hide.tap()
        XCTAssertTrue(canoe.waitForNonExistence(timeout: 5))
        let undo = app.buttons["sport.undoHide"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(canoe.waitForExistence(timeout: 5))
        attachScreenshot("restored with undo")

        // Hidden for real: it stays gone after the toast, and Settings shows it as hidden.
        canoe.swipeLeft()
        hide.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 10))
        XCTAssertFalse(canoe.exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Hidden"].waitForExistence(timeout: 10))
    }

    /// Hiding a sport in Settings removes its card; the last visible sport cannot be hidden.
    func testHiddenSportLeavesTheGrid() {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sport.canoe"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons["settings.sport.canoe"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let visible = app.switches["sportSettings.visible"]
        scrollTo(visible, in: app)
        visible.switches.firstMatch.tap()
        XCTAssertEqual(visible.value as? String, "0")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Hidden"].waitForExistence(timeout: 10))
        attachScreenshot("settings with hidden sport")

        app.tabBars.buttons["Record"].tap()
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sport.canoe"].exists)
    }

    /// Picks `option` from a menu-style picker in a form.
    private func choose(_ option: String, from picker: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(option) in the menu")
        item.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
    }
}
