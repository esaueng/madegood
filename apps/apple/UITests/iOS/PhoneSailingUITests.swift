import XCTest

/// Sailing on the iPhone: the live sailing card during a demo beat (`-demoTacks`: wind
/// from north, a tack every 31 s), and wind, VMG and the maneuver list in the detail of
/// the demo history's 48-minute beat (wind from north, a tack every 4 minutes).
final class PhoneSailingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveSailingCard() {
        let app = launchDemoApp(extraArguments: ["-demoTacks", "-app.appearance", "light"])
        let start = app.buttons["sport.sailing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()

        let card = element("live.sailing", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let wind = element("metric.wind", in: app)
        scrollTo(wind, in: app)
        XCTAssertEqual(wind.value as? String, "Unavailable")
        waitFor(wind, value: "(00[0-5]|35[5-9]) degrees true", timeout: 120)
        waitFor(element("metric.tacks", in: app), value: "[1-9][0-9]*", timeout: 30)
        XCTAssertEqual(element("metric.gybes", in: app).value as? String, "0")
        waitFor(element("metric.vmg", in: app), value: "[0-9.]+ knots", timeout: 10)
        scrollTo(element("metric.gybes", in: app), in: app)
        attachScreenshot("1 live sailing")
        endSession(app)
    }

    @MainActor
    func testSessionDetailEstimatesWindAndListsTacks() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        let sailing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing")
            .containing(.staticText, identifier: "48:00").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()

        let windRow = app.buttons["moments.wind.edit"]
        scrollTo(windRow, in: app)
        let estimated = NSPredicate(format: "label MATCHES %@", "True wind from, (0|35[5-9]|[1-5])° \\(estimated\\)")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: estimated, object: windRow)], timeout: 15),
            .completed, windRow.label)

        let first = app.buttons["moments.maneuver.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        scrollTo(first, in: app)
        XCTAssertTrue(first.label.hasPrefix("Tack · 4:0"), first.label)
        // An 8 s tack between 45° and 315°: about 90° between the legs' mean courses.
        XCTAssertNotNil(first.label.range(of: "Turn (8[0-9]|9[0-9])°", options: .regularExpression), first.label)
        attachScreenshot("1 sailing moments")
        first.tap()
        let range = app.staticTexts["replay.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.label.hasPrefix("Tack · 4:0"), range.label)

        // Eleven tacks in 48 minutes, then the VMG summary.
        let last = app.buttons["moments.maneuver.10"]
        scrollTo(last, in: app)
        XCTAssertFalse(app.buttons["moments.maneuver.11"].exists)
        let upwind = element("moments.vmg.upwind", in: app)
        scrollTo(upwind, in: app)
        XCTAssertTrue(upwind.label.hasPrefix("VMG upwind, "), upwind.label)

        // The demo build answers for Open-Meteo without the network (10° at 6 m/s).
        let fetch = app.buttons["moments.openMeteo.fetch"]
        scrollTo(fetch, in: app)
        attachScreenshot("2 vmg and open-meteo button")
        fetch.tap()
        let result = element("moments.openMeteo.result", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("10°"), result.label)
        attachScreenshot("3 open-meteo comparison")
    }

    @MainActor
    func testOpenMeteoFailureKeepsTheEstimate() {
        let app = launchDemoHistory(extraArguments: ["-demoOpenMeteoOffline"])
        app.tabBars.buttons["History"].tap()
        let sailing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing")
            .containing(.staticText, identifier: "48:00").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()
        let fetch = app.buttons["moments.openMeteo.fetch"]
        scrollTo(fetch, in: app)
        fetch.tap()
        waitFor(fetch, label: "Open-Meteo unavailable\\. Try again", timeout: 10)
        // The track's own analysis stays.
        XCTAssertTrue(element("moments.vmg.upwind", in: app).exists)
        attachScreenshot("open-meteo offline")
    }

    private func waitFor(_ element: XCUIElement, value pattern: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value MATCHES %@", pattern), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never matched \(pattern); last value: \(String(describing: element.value))")
    }

    private func waitFor(_ element: XCUIElement, label pattern: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES %@", pattern), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never matched \(pattern); last label: \(element.label)")
    }
}
