import XCTest

/// Sailing on the iPhone: the live sailing card during a demo beat (`-demoTacks`: wind
/// from north, a tack every 31 s), and wind, VMG and the maneuver list in the detail of
/// the demo history's 48-minute beat (wind from north, a tack every 4 minutes). The
/// track alone only gives the wind's axis, so until Apple Weather chooses a side nothing is
/// called upwind, downwind, a tack or a gybe.
final class PhoneSailingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveSailingCard() {
        let app = launchDemoApp(extraArguments: ["-demoTacks", "-demoOmitMapKit", "-app.appearance", "light"])
        let start = app.buttons["sport.sailing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()

        let card = element("live.sailing", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let wind = element("metric.wind", in: app)
        scrollTo(wind, in: app)
        XCTAssertEqual(wind.value as? String, "Unavailable")
        // Both ends of the axis: "000°/180°" is spoken "000°/180 degrees true".
        waitFor(wind, value: "(00[0-5]|35[5-9])°/(17[5-9]|18[0-5]) degrees true", timeout: 120)
        waitFor(element("metric.maneuvers", in: app), value: "[1-9][0-9]*", timeout: 30)
        XCTAssertFalse(element("metric.tacks", in: app).exists)
        XCTAssertFalse(element("metric.gybes", in: app).exists)
        XCTAssertEqual(element("metric.vmg", in: app).label, "VMG")
        waitFor(element("metric.vmg", in: app), value: "[0-9.]+ knots", timeout: 10)
        scrollTo(element("metric.maneuvers", in: app), in: app)
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
        // Read the session with the panel at full height: the Apple Weather result re-runs
        // the analysis, and the list must keep enough rows loaded to find it after.
        expandSessionPanel(in: app)

        let windRow = app.buttons["moments.wind.edit"]
        scrollTo(windRow, in: app)
        let estimated = NSPredicate(
            format: "label MATCHES %@", "Wind axis, (0|35[5-9]|[1-5])°/(17[5-9]|18[0-5])° \\(estimated\\)")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: estimated, object: windRow)], timeout: 15),
            .completed, windRow.label)

        let first = app.buttons["moments.maneuver.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        scrollTo(first, in: app)
        XCTAssertTrue(first.label.hasPrefix("Tack or gybe · 4:0"), first.label)
        // An 8 s tack between 45° and 315°: about 90° between the legs' mean courses.
        XCTAssertNotNil(first.label.range(of: "Turn (8[0-9]|9[0-9])°", options: .regularExpression), first.label)
        attachScreenshot("1 sailing moments")
        first.tap()
        let range = app.staticTexts["replay.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.label.hasPrefix("Tack or gybe · 4:0"), range.label)

        // Eleven tacks in 48 minutes, then the VMG summary.
        let last = app.buttons["moments.maneuver.10"]
        scrollTo(last, in: app)
        XCTAssertFalse(app.buttons["moments.maneuver.11"].exists)
        XCTAssertFalse(element("moments.vmg.upwind", in: app).exists)
        let axis = element("moments.vmg.axis", in: app)
        scrollTo(axis, in: app)
        XCTAssertTrue(axis.label.hasPrefix("VMG along the wind axis, "), axis.label)

        // The demo build answers for Apple Weather without the network (10° at 6 m/s). The
        // button says what is sent before the tap.
        let fetch = app.buttons["moments.appleWeather.fetch"]
        scrollTo(fetch, in: app)
        XCTAssertTrue(fetch.label.contains("approximate area (~11 km) and time range with Apple"), fetch.label)
        attachScreenshot("2 vmg and apple weather button")
        fetch.tap()
        // The prior re-runs the analysis, and the list grows again, so find the row after.
        let resolvedTack = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'moments.maneuver.' AND label BEGINSWITH 'Tack · '")
        ).firstMatch
        XCTAssertTrue(resolvedTack.waitForExistence(timeout: 15))
        let result = element("moments.appleWeather.result", in: app)
        scrollTo(result, in: app)
        XCTAssertTrue(result.label.contains("10°"), result.label)

        // 10° is within 60° of north, so the side is chosen: tacks and upwind VMG now.
        let upwind = element("moments.vmg.upwind", in: app)
        XCTAssertTrue(upwind.waitForExistence(timeout: 5))
        XCTAssertTrue(upwind.label.hasPrefix("VMG upwind, "), upwind.label)
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(last.label.hasPrefix("Tack · 44:0"), last.label)
        attachScreenshot("3 apple weather comparison")
    }

    @MainActor
    func testAppleWeatherFailureKeepsTheEstimate() {
        let app = launchDemoHistory(extraArguments: ["-demoWeatherOffline"])
        app.tabBars.buttons["History"].tap()
        let sailing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing")
            .containing(.staticText, identifier: "48:00").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()
        let fetch = app.buttons["moments.appleWeather.fetch"]
        scrollTo(fetch, in: app)
        fetch.tap()
        waitFor(fetch, label: "Apple Weather unavailable\\. Try again.*", timeout: 10)
        // The track's own analysis stays.
        XCTAssertTrue(element("moments.vmg.axis", in: app).exists)
        attachScreenshot("apple weather offline")
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
