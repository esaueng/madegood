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
        let app = launchDemoHistory(extraArguments: ["-app.appearance", appearance])
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 15))
        sleep(2)  // last-session lines come from the history summaries
        XCTAssertTrue(app.descendants(matching: .any)["start.header"].exists)
        attachScreenshot("\(appearance) record")

        // Scrolled partway: rows soften under the status bar instead of running into it.
        // (The compact header and top cards scroll out of the list, so follow See All.)
        let card = app.buttons["recent.seeAll"]
        let restingY = card.frame.minY
        let start = app.cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertLessThan(card.frame.minY, restingY - 20, "the start list should scroll")
        attachScreenshot("\(appearance) record scrolled")

        // "See All" beside Recent opens History.
        let seeAll = app.buttons["recent.seeAll"]
        for _ in 0..<3 where !seeAll.isHittable { app.swipeUp() }
        seeAll.tap()
        let rows = app.buttons.matching(identifier: "session.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        // The cards are tall, so the list loads only the first rows; the totals card
        // counts every demo session.
        waitForLabelPrefix(element("history.totals", in: app), "3\u{00A0}sessions\u{00A0}· ")
        sleep(2)  // let the summaries finish computing
        attachScreenshot("\(appearance) history")

        // Open the 48-minute sailing fixture.
        let sailing = rows.containing(.staticText, identifier: "Sailing")
            .containing(.staticText, identifier: "48:00").firstMatch
        scrollTo(sailing, in: app)
        sailing.tap()
        XCTAssertTrue(element("replay.map", in: app).waitForExistence(timeout: 20))
        sleep(2)  // map tiles
        attachScreenshot("\(appearance) detail top")
        scrollTo(element("chart.speed", in: app), in: app)
        attachScreenshot("\(appearance) detail charts")
        scrollTo(app.staticTexts["stat.Distance"], in: app)
        scrollTo(app.buttons["replay.lap.1"], in: app)
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

final class HistoryFiltersUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSportAndDatesFilterRowsAndTotalsTogether() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let totals = element("history.totals", in: app)
        XCTAssertTrue(totals.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "\u{00A0}km"), object: totals)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 15), .completed)
        let allTotals = totals.label
        XCTAssertTrue(allTotals.hasPrefix("3\u{00A0}sessions\u{00A0}· "), allTotals)
        // VoiceOver hears what the card adds to the totals line: the days and the best 10 s.
        XCTAssertTrue((totals.value as? String)?.hasPrefix("on 3 days, fastest 10 seconds ") == true)

        let rows = app.buttons.matching(identifier: "session.row")
        app.buttons["history.sportFilter"].tap()
        app.buttons["Windsurfing"].tap()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.staticTexts["Windsurfing"].exists)
        XCTAssertTrue(totals.label.hasPrefix("1\u{00A0}session\u{00A0}· "))
        XCTAssertTrue(totals.label.contains("\u{00A0}nm"))
        XCTAssertTrue(totals.label.hasSuffix("25\u{00A0}min"))
        XCTAssertTrue((totals.value as? String)?.hasPrefix("on 1 day, ") == true)
        XCTAssertEqual(app.staticTexts["month.totals"].firstMatch.label, totals.label)
        attachScreenshot("Windsurfing history with route preview")

        let dateFilter = app.buttons["history.dateFilter"]
        dateFilter.tap()
        app.buttons["Last 7 Days"].tap()
        XCTAssertTrue(app.staticTexts["No matching sessions"].exists)
        XCTAssertFalse(totals.exists)
        XCTAssertEqual(rows.count, 0)

        dateFilter.tap()
        app.buttons["Choose Dates…"].tap()
        XCTAssertTrue(app.navigationBars["Choose Dates"].waitForExistence(timeout: 5))
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.staticTexts["No matching sessions"].exists)

        app.buttons["Clear Filters"].tap()
        waitForLabel(totals, allTotals)
        XCTAssertTrue(rows.firstMatch.exists)
    }

    /// Regression (QA-02): at the largest text size the totals wrapped "24.2" / "km" onto
    /// separate lines. They may wrap between metrics, after a "·", but never inside one.
    @MainActor
    func testTotalsWrapOnlyBetweenMetricsAtLargestText() {
        let app = launchDemoHistory(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let totals = element("history.totals", in: app)
        XCTAssertTrue(totals.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "\u{00A0}km"), object: totals)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 15), .completed, totals.label)
        attachScreenshot("History totals at the largest text size")
        // At this size the totals card fills the screen, so the month header is below it.
        let monthTotals = app.staticTexts["month.totals"].firstMatch
        scrollTo(monthTotals, in: app)
        XCTAssertTrue(monthTotals.exists)

        for label in [totals.label, monthTotals.label] {
            // Text breaks only at ordinary spaces; each must follow a metric separator.
            let pieces = label.split(separator: " ")
            XCTAssertGreaterThanOrEqual(pieces.count, 3, label)
            for piece in pieces.dropLast() {
                XCTAssertTrue(piece.hasSuffix("\u{00A0}·"), "line break inside a metric: \(label)")
            }
            XCTAssertNotNil(label.range(of: #"\d\x{00A0}km"#, options: .regularExpression), label)
        }
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
        let app = launchDemoHistory()
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
        setSwitch(toggle, on: on, in: app)
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func expectHistory(showing text: String, _ app: XCUIApplication) {
        app.tabBars.buttons["History"].tap()
        let label = app.staticTexts[text]
        for _ in 0..<6 where !label.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(label.exists, "History never showed \(text)")
    }
}
