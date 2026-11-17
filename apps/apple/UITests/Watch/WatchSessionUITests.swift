import XCTest

/// Walks through a demo kayak session on the watch: start, metrics, controls, map, end,
/// summary. The demo boat moves at 2.5 m/s, which kayak shows as 9.0 km/h.
final class WatchSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoSession() {
        let app = launchDemoApp()

        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        attachScreenshot("1 sports")
        let started = Date()
        kayak.tap()

        // Metrics page: speed from the engine, and distance accumulating.
        let speed = app.staticTexts["metric.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForLabel(speed, "9.0 km/h")
        XCTAssertTrue(app.staticTexts["field.Distance"].exists)
        attachScreenshot("2 metrics")

        // Controls sit above the metrics.
        goToPage(1, app)
        let pause = app.buttons["control.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        attachScreenshot("3 controls")
        pause.tap()
        let resume = app.buttons["control.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        attachScreenshot("4 paused")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        app.buttons["control.lap"].tap()

        goToPage(2, app)
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        waitForLabel(app.staticTexts["metric.lap"], "Lap 2")

        // The map is below the metrics, and swiping must still leave it (a review found
        // an interactive map trapped the user there).
        goToPage(3, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        attachScreenshot("5 map")
        goToPage(2, app)
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        goToPage(1, app)
        XCTAssertTrue(app.buttons["control.end"].waitForExistence(timeout: 10))

        // Man-overboard: marks the position and shows the way back on its own page.
        app.buttons["control.mob"].tap()
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        attachScreenshot("6 man overboard")
        // The MOB page is now page 1, so the controls are page 2.
        goToPage(2, app)
        XCTAssertTrue(app.buttons["control.end"].waitForExistence(timeout: 10))

        app.buttons["control.end"].tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'End' AND identifier != 'control.end'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let ended = Date()

        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["field.Distance"].exists)
        XCTAssertEqual(app.staticTexts["field.Laps"].label, "2")
        // Regression check from review: the demo once ran on a 5x clock, so the session
        // time outran the real session and the saved events.
        let time = app.staticTexts["field.Time"].label.split(separator: ":").compactMap { Double($0) }
        XCTAssertEqual(time.count, 2)
        let seconds = (time.first ?? 0) * 60 + (time.last ?? 0)
        XCTAssertLessThanOrEqual(seconds, ended.timeIntervalSince(started) + 2)
        attachScreenshot("7 summary")
        done.tap()

        // Regression checks from review: an uncleared mark outlives the session and a
        // relaunch, with its own location updates.
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        attachScreenshot("8 man overboard after session")
        app.terminate()
        // Relaunching while the old process is still exiting fails on slower runners
        // ("Application has termination assertions"), so wait for it to be gone.
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        sleep(3)
        let relaunched = launchDemoApp()
        XCTAssertTrue(relaunched.buttons["mob.clear"].waitForExistence(timeout: 15))
        // A new session can start while the mark is kept (review of #27).
        relaunched.buttons["mob.newSession"].tap()
        XCTAssertTrue(relaunched.buttons["sport.kayak"].waitForExistence(timeout: 10))
        relaunched.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(relaunched.buttons["mob.clear"].waitForExistence(timeout: 10))
        relaunched.buttons["mob.clear"].tap()
        XCTAssertTrue(relaunched.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    /// Moves the vertical page view to `page` (1-based) by dragging. XCUITest's quick
    /// swipes and Digital Crown rotation did not change page in the simulator.
    private func goToPage(_ page: Int, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let indicator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH 'page '")).firstMatch
        for _ in 0..<8 {
            guard let value = indicator.value as? String,
                let current = Int(value.split(separator: " ").dropFirst().first ?? "")
            else { break }
            if current == page { return }
            // A slow drag, like a finger: up for the next page, down for the previous one.
            let window = app.windows.firstMatch
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let (from, to) = current < page ? (low, high) : (high, low)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.05)
            sleep(1)
        }
        XCTFail(
            "Could not reach page \(page); indicator: \(String(describing: indicator.value))", file: file, line: line)
    }
}
