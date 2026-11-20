import XCTest

final class PhoneMomentsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPaddlingSplitsUseDisplayUnitsAndHighlightSeparateMovingSpans() {
        let app = launchDemoApp(extraArguments: [
            "-demoMoments", "-demoHistoryNamespace", UUID().uuidString,
            "-settings.distanceUnit.kayak", "mi", "-settings.speedUnit.kayak", "mph",
        ])
        openSession("Kayak", in: app)

        let full = app.buttons["moments.split.1"]
        scrollTo(full, in: app, column: 0.025)
        waitForLabel(full, "Split 1, 0.62 mi · 5:33 moving · 6.7 mph")
        let partial = app.buttons["moments.split.2"]
        XCTAssertFalse(app.buttons["moments.wind.edit"].exists)

        full.tap()
        let range = app.staticTexts["replay.range"]
        waitForLabel(range, "Split 1 · 0:00 to 6:34.333")
        XCTAssertEqual(range.value as? String, "2 highlighted route segments")
        XCTAssertEqual(app.staticTexts["stat.Elapsed"].label, "0:00")
        XCTAssertEqual(element("replay.position", in: app).value as? String, "0:00")
        XCTAssertTrue(app.staticTexts["stat.GPS speed"].label.hasSuffix(" mph"))

        scrollTo(partial, in: app, column: 0.025)
        waitForLabel(partial, "Split 2 (partial), 0.38 mi · 3:25 moving · 6.7 mph")
        XCTAssertFalse(app.buttons["moments.split.3"].exists)
        partial.tap()
        waitForLabel(range, "Split 2 (partial) · 6:34.333 to 10:00")
        XCTAssertEqual(app.staticTexts["stat.Elapsed"].label, "6:34.333")
        // Moving the annotation can replace its accessibility element. Resolve it again
        // instead of querying the snapshot from the first split.
        XCTAssertEqual(element("replay.position", in: app).value as? String, "6:34.333")
    }

    @MainActor
    func testSailingValidatesLocalWindAndSeeksToTheCrossing() {
        let app = launchDemoApp(extraArguments: [
            "-demoMoments", "-demoOmitMapKit", "-demoHistoryNamespace", UUID().uuidString,
        ])
        openSession("Sailing", in: app)

        let wind = app.buttons["moments.wind.edit"]
        let maneuver = app.buttons["moments.maneuver.0"]
        scrollTo(wind, in: app)
        XCTAssertTrue(app.staticTexts["Add a wind direction to look for tacks and gybes."].exists)
        XCTAssertFalse(maneuver.exists)
        wind.tap()

        let field = app.textFields["moments.wind.direction"]
        let done = app.buttons["moments.wind.apply"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("361")
        XCTAssertTrue(app.staticTexts["moments.wind.invalid"].exists)
        XCTAssertFalse(done.isEnabled)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "90")
        XCTAssertTrue(done.isEnabled)
        done.tap()

        XCTAssertTrue(app.staticTexts["No tacks or gybes detected."].waitForExistence(timeout: 10))
        XCTAssertFalse(maneuver.exists)
        wind.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "0")
        done.tap()

        XCTAssertTrue(maneuver.waitForExistence(timeout: 10))
        scrollTo(maneuver, in: app)
        XCTAssertTrue(maneuver.label.hasPrefix("Tack · 0:16,"))
        maneuver.tap()
        let range = app.staticTexts["replay.range"]
        waitForLabel(range, "Tack · 0:16 · 0:13 to 0:19")
        XCTAssertEqual(app.staticTexts["stat.Elapsed"].label, "0:16")
        XCTAssertEqual(element("replay.position", in: app).value as? String, "0:16")

        scrollTo(wind, in: app)
        wind.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        done.tap()
        XCTAssertTrue(app.staticTexts["Add a wind direction to look for tacks and gybes."].waitForExistence(timeout: 5))
        XCTAssertFalse(maneuver.exists)
        XCTAssertFalse(range.exists)
    }

    @MainActor
    private func openSession(_ sport: String, in app: XCUIApplication) {
        app.tabBars.buttons["History"].tap()
        let filter = app.buttons["history.sportFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        app.buttons[sport].tap()
        let row = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: sport).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        scrollTo(row, in: app)
        row.tap()
    }
}
