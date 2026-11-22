import XCTest

/// Walks through a demo kayak session on the watch: start card, metrics, controls, strokes,
/// map, end, summary. The demo boat moves at 2.5 m/s, which kayak shows as 9.0 km/h.
final class WatchSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoSession() {
        let app = launchDemoApp()

        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        attachScreenshot("1 sport cards")
        let started = Date()
        scrollTo(kayak, in: app)
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

        // Kayak's sport page: stroke rate and count from the demo's synthetic wrist
        // motion (64 SPM).
        goToPage(3, app)
        let strokeRate = app.staticTexts["metric.strokeRate"]
        XCTAssertTrue(strokeRate.waitForExistence(timeout: 10))
        XCTAssertEqual(strokeRate.label, "Stroke rate")
        let settled = NSPredicate(format: "value MATCHES %@", "6[2-6] strokes per minute")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: strokeRate)], timeout: 30),
            .completed, "stroke rate never settled; last value: \(strokeRate.value ?? "missing")")
        let strokes = app.staticTexts["field.Strokes"]
        XCTAssertGreaterThan(Int(strokes.label) ?? 0, 0)
        XCTAssertTrue(app.staticTexts["field.Per stroke"].label.hasSuffix(" m"))
        attachScreenshot("5 strokes")

        // The map is below the sport page, and swiping must still leave it (a review found
        // an interactive map trapped the user there).
        goToPage(4, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        attachScreenshot("5b map")
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
        XCTAssertGreaterThan(Int(app.staticTexts["field.Strokes"].label) ?? 0, 0)
        // Regression check from review: the demo once ran on a 5x clock, so the session
        // time outran the real session and the saved events.
        let time = app.staticTexts["field.Time"].label.split(separator: ":").compactMap { Double($0) }
        XCTAssertEqual(time.count, 2)
        let seconds = (time.first ?? 0) * 60 + (time.last ?? 0)
        XCTAssertLessThanOrEqual(seconds, ended.timeIntervalSince(started) + 2)
        XCTAssertTrue(app.staticTexts["summary.delivery"].exists || app.otherElements["summary.delivery"].exists)
        attachScreenshot("7 summary")
        done.tap()

        // Regression checks from review: an uncleared mark outlives the session, and a
        // new session can start while it is kept.
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        attachScreenshot("8 man overboard after session")
        app.buttons["mob.newSession"].tap()
        XCTAssertTrue(kayak.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        // One tap only asks: a stray press must not lose the way back.
        clear.tap()
        let clearMark = app.buttons["Clear Mark"]
        XCTAssertTrue(clearMark.waitForExistence(timeout: 10))
        attachScreenshot("9 clear mark confirmation")
        clearMark.tap()
        XCTAssertTrue(kayak.waitForExistence(timeout: 10))
    }

    /// Regression check from review: a mark survives relaunching the app. Skipped on CI,
    /// where the simulator often cannot relaunch the watch app ("termination assertions",
    /// or the app missing from its library right after it exits).
    func testManOverboardSurvivesRelaunch() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Relaunching the watch app is unreliable on CI simulators.")
        }
        let app = launchDemoApp()
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        scrollTo(kayak, in: app)
        kayak.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))
        waitForLabel(app.staticTexts["metric.speed"], "9.0 km/h")
        goToPage(1, app)
        app.buttons["control.mob"].tap()
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        sleep(3)
        let relaunched = launchDemoApp(resetSettings: false)
        XCTAssertTrue(relaunched.buttons["mob.clear"].waitForExistence(timeout: 15))
        clearManOverboardMark(relaunched)
        XCTAssertTrue(relaunched.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }
}
