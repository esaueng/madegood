import XCTest

extension XCTestCase {
    /// Moves the vertical page view to `page` (1-based) by dragging. XCUITest's quick
    /// swipes and Digital Crown rotation did not change page in the simulator.
    func goToPage(_ page: Int, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
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

    /// Ends the session from the controls page (`controlsPage`, 1-based) and dismisses the
    /// summary.
    func endWatchSession(_ app: XCUIApplication, controlsPage: Int = 1) {
        goToPage(controlsPage, app)
        let end = app.buttons["control.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        end.tap()
        let confirm = app.buttons["control.endConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        done.tap()
    }

    /// Clears the man-overboard mark shown on screen, through its confirmation.
    func clearManOverboardMark(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), file: file, line: line)
        clear.tap()
        let confirm = app.buttons["mob.clearConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), file: file, line: line)
        confirm.tap()
    }
}
