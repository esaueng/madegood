import XCTest

/// Windsurf speed categories on the iPhone: live during a demo session (a steady 8 m/s),
/// and in the detail of the demo history's windsurfing session.
final class PhoneWindsurfUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveSpeedBests() {
        // MapKit can stall accessibility snapshots on the simulator while the route updates.
        let app = launchDemoApp(extraArguments: ["-demoOmitMapKit", "-app.appearance", "light"])
        let start = app.buttons["sport.windsurfing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()

        let speed = element("metric.speed", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForValue("15.6 knots", on: "metric.speed", in: app, timeout: 15)
        let bests = element("live.speedBests", in: app)
        XCTAssertTrue(bests.waitForExistence(timeout: 10))
        waitForValue("15.6 knots", on: "speed.100m", in: app, timeout: 40)
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
        let rows = app.buttons.matching(identifier: "session.row")
        let windsurfing = rows.containing(.staticText, identifier: "Windsurfing").firstMatch
        // The History list loads rows as they scroll in; the windsurf session is the third.
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
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

    @MainActor
    private func waitForValue(
        _ value: String, on identifier: String, in app: XCUIApplication, timeout: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Match the identifier and value in a single accessibility query on each check.
        let match = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value == %@", identifier, value)
        ).firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: timeout), "\(identifier) never showed \(value)", file: file, line: line)
    }
}
