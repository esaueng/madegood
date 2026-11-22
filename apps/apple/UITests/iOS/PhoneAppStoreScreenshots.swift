import XCTest

/// The iPhone App Store screenshot set, from synthetic demo data only (`-demoSession`,
/// `-demoHistory`, canned weather). `scripts/app-store-screenshots` runs this class on the
/// largest iPhone simulator and exports the attachments named `appstore NN-name`.
final class PhoneAppStoreScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let look = ["-app.appearance", "light"]

    /// The start screen: local conditions, sport cards and the last sessions.
    @MainActor
    func test01Start() {
        let app = launchDemoHistory(extraArguments: look + ["-demoWeather", "sailingBreeze"])
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("weather.card", in: app).waitForExistence(timeout: 10))
        sleep(3)  // last-session lines come from the history summaries
        attachAppStoreScreenshot("01-start")
    }

    /// A live sailing session on a beat: speed, wind axis, VMG and maneuvers.
    @MainActor
    func test02LiveSailing() {
        let app = launchDemoApp(extraArguments: look + ["-demoTacks"])
        let start = app.buttons["sport.sailing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let wind = element("metric.wind", in: app)
        XCTAssertTrue(wind.waitForExistence(timeout: 15))
        wait(for: wind, value: "(00[0-5]|35[5-9])°/(17[5-9]|18[0-5]) degrees true", timeout: 150)
        wait(for: element("metric.maneuvers", in: app), value: "[1-9][0-9]*", timeout: 30)
        sleep(2)
        attachAppStoreScreenshot("02-live")
        endSession(app)
    }

    /// History: every sport's sessions with route previews and totals.
    @MainActor
    func test03History() {
        let app = launchDemoHistory(extraArguments: look)
        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        // The cards are tall, so the list loads only the first few rows; the totals card
        // counts every demo session once all three are analyzed.
        waitForLabelPrefix(element("history.totals", in: app), "3\u{00A0}sessions\u{00A0}· ")
        sleep(3)  // summaries and route previews
        attachAppStoreScreenshot("03-history")
    }

    /// The 48-minute demo beat in History: the speed-coloured map with the replay part
    /// way through, the session's stats, and the wind estimate and tacks.
    @MainActor
    func test04SessionDetail() {
        let app = launchDemoHistory(extraArguments: look)
        openHistorySession(sport: "Sailing", duration: "48:00", in: app)
        // Move the replay to the middle of a leg, so the readout shows the boat moving.
        let chart = element("chart.speed", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        sleep(3)  // map tiles
        attachAppStoreScreenshot("04-session-map")

        bringToTop(app.staticTexts["stat.Distance"], in: app)
        sleep(1)
        attachAppStoreScreenshot("05-session-stats")

        // The demo build answers for Apple Weather without the network, which tells tacks
        // from gybes and gives upwind VMG.
        let fetch = app.buttons["moments.appleWeather.fetch"]
        scrollTo(fetch, in: app, column: 0.06)
        fetch.tap()
        let tack = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'moments.maneuver.' AND label BEGINSWITH 'Tack · '")
        ).firstMatch
        XCTAssertTrue(tack.waitForExistence(timeout: 15))
        bringToTop(app.buttons["moments.wind.edit"], in: app)
        sleep(1)
        attachAppStoreScreenshot("06-sailing-tacks")
    }

    /// A kayak session's strokes: rate chart, count and distance per stroke.
    @MainActor
    func test07Paddling() {
        let app = launchDemoHistory(extraArguments: look)
        openHistorySession(sport: "Kayak", duration: nil, in: app)
        bringToTop(app.staticTexts["stat.Strokes"], in: app, at: 0.21)  // keeps the section title
        sleep(1)
        attachAppStoreScreenshot("07-paddling-strokes")
    }

    /// The anchor alarm, armed at the demo boat's position.
    @MainActor
    func test08AnchorAlarm() {
        let app = launchDemoApp(extraArguments: look)
        let open = app.buttons["anchor.open"]
        scrollTo(open, in: app)
        open.tap()
        let arm = app.buttons["anchor.arm"]
        scrollTo(arm, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: arm)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        arm.tap()
        waitForLabel(app.staticTexts["anchor.status"], "Armed", timeout: 10)
        sleep(3)  // map tiles
        attachAppStoreScreenshot("08-anchor-alarm")
        let disarm = app.buttons["anchor.disarm"]
        scrollTo(disarm, in: app)
        disarm.tap()
        app.buttons["anchor.confirmDisarm"].firstMatch.tap()
    }

    // MARK: Helpers

    private func openHistorySession(sport: String, duration: String?, in app: XCUIApplication) {
        app.tabBars.buttons["History"].tap()
        var row = app.buttons.matching(identifier: "session.row").containing(.staticText, identifier: sport)
        if let duration { row = row.containing(.staticText, identifier: duration) }
        let match = row.firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 15))
        scrollTo(match, in: app)
        match.tap()
        XCTAssertTrue(element("replay.map", in: app).waitForExistence(timeout: 20))
    }

    /// Scrolls until `element` sits just below the navigation bar. Drags run down the left
    /// margin, clear of the charts' scrub gesture and the interactive map.
    private func bringToTop(_ element: XCUIElement, in app: XCUIApplication, at top: CGFloat = 0.17) {
        scrollTo(element, in: app, column: 0.06)
        let window = app.windows.firstMatch
        for _ in 0..<4 {
            let offset = element.frame.minY - window.frame.height * top
            guard abs(offset) > 12 else { return }
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
            let step = max(-window.frame.height * 0.3, min(offset, window.frame.height * 0.4))
            let to = from.withOffset(CGVector(dx: 0, dy: -step))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            sleep(1)
        }
    }

    private func wait(for element: XCUIElement, value pattern: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value MATCHES %@", pattern), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never matched \(pattern); last value: \(String(describing: element.value))")
    }
}
