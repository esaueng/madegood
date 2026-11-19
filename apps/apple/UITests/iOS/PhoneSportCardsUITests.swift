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
        // The switch's value follows the stored setting; a slow simulator can report the old
        // value just after the tap.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: visible)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 10), .completed, "Canoe never became hidden")
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

/// Dragging the start screen's sports into the user's own order.
final class PhoneSportOrderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Touch and hold a card, drag it below another: the new order shows, survives a
    /// relaunch, and Settings can put it back to most recent first.
    func testDragReordersSportsAndSticks() {
        var app = launchDemoApp()
        let canoe = app.buttons["sport.canoe"]
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(canoe.waitForExistence(timeout: 15))
        XCTAssertTrue(sailing.waitForExistence(timeout: 5))
        let canoeWasBelow = canoe.frame.minY > sailing.frame.minY
        let (moving, target) = canoeWasBelow ? (canoe, sailing) : (sailing, canoe)
        moving.press(forDuration: 1.0, thenDragTo: target)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (canoe.frame.minY > sailing.frame.minY) != canoeWasBelow }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "The drag didn't reorder the cards")
        attachScreenshot("reordered")

        // The order is kept across launches.
        app = launchDemoApp(resetSettings: false)
        XCTAssertTrue(canoe.waitForExistence(timeout: 15))
        XCTAssertNotEqual(app.buttons["sport.canoe"].frame.minY > app.buttons["sport.sailing"].frame.minY, canoeWasBelow)

        // Settings puts it back to most recent first.
        app.tabBars.buttons["Settings"].tap()
        let recent = app.buttons["settings.recentOrder"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Record"].tap()
        XCTAssertTrue(app.buttons["sport.canoe"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["sport.canoe"].frame.minY > app.buttons["sport.sailing"].frame.minY, canoeWasBelow)
    }
}

/// The start screen's local conditions card, from canned conditions (no network).
final class PhoneWeatherUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testConditionsCardShowsMoodWarningAndRatings() {
        let app = launchDemoApp(extraArguments: ["-demoWeather", "stormComing"])
        let card = app.descendants(matching: .any)["weather.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains("Storm on the way"), card.label)
        XCTAssertTrue(card.label.contains("Thunder likely"), card.label)
        XCTAssertTrue(card.label.contains("Sailing: Stay ashore"), card.label)
        attachScreenshot("storm coming")
    }

    /// Without a choice the card offers to turn on; Not now hides it for good.
    func testOfferCanBeDeclined() {
        let app = launchDemoApp()
        let notNow = app.buttons["weather.notNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["weather.enable"].exists)
        attachScreenshot("weather offer")
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sport.sailing"].exists)
    }
}
