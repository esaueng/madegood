import XCTest

/// Windsurf speed categories on the iPhone: live during a demo session (a steady 8 m/s),
/// and in the detail of the demo history's windsurfing session.
final class PhoneWindsurfUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveSpeedBests() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "light"])
        let start = app.buttons["sport.windsurfing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()

        let speed = element("metric.speed", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForValue(speed, "15.6 knots", timeout: 15)
        let bests = element("live.speedBests", in: app)
        XCTAssertTrue(bests.waitForExistence(timeout: 10))
        let hundred = element("speed.100m", in: app)
        waitForValue(hundred, "15.6 knots", timeout: 40)
        XCTAssertEqual(element("speed.2s", in: app).value as? String, "15.6 knots")
        XCTAssertEqual(element("speed.alpha500", in: app).value as? String, "Unavailable")
        scrollTo(element("speed.alpha500", in: app), in: app)
        attachScreenshot("1 live speed bests")
        endSession(app)
    }

    @MainActor
    func testSessionDetailSpeedBests() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        let windsurfing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Windsurfing").firstMatch
        XCTAssertTrue(windsurfing.waitForExistence(timeout: 15))
        scrollTo(windsurfing, in: app)
        windsurfing.tap()

        let interval = app.staticTexts["replay.range"]
        // The demo runs back and forth along one line, so it has an alpha 500.
        let alpha = app.buttons["replay.Alpha 500"]
        scrollTo(alpha, in: app)
        XCTAssertTrue(alpha.label.hasSuffix(" kn"), alpha.label)
        XCTAssertEqual(app.staticTexts["stat.1 hour"].label, "–")
        attachScreenshot("1 speed bests")
        alpha.tap()
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        XCTAssertTrue(interval.label.hasPrefix("Alpha 500 · "), interval.label)
        attachScreenshot("2 alpha in replay")

        let fiveByTen = app.buttons["replay.5 × 10 s"]
        scrollTo(fiveByTen, in: app)
        fiveByTen.tap()
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        XCTAssertTrue(interval.label.hasPrefix("5 × 10 s · "), interval.label)
        attachScreenshot("3 five by ten in replay")
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never showed \(value); last value: \(String(describing: element.value))")
    }
}
