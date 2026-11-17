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

        app.buttons["control.end"].tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'End' AND identifier != 'control.end'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["field.Distance"].exists)
        XCTAssertEqual(app.staticTexts["field.Laps"].label, "2")
        attachScreenshot("6 summary")
        done.tap()
        XCTAssertTrue(kayak.waitForExistence(timeout: 10))
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
