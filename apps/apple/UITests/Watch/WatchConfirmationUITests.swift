import XCTest

/// The full-screen confirmations before clearing a man-overboard mark and ending a session.
/// Regression checks from review: with the system dialog, the destructive button sat where
/// the opening button was, so a double tap (or a wet sleeve) went straight through; the only
/// way back was a small corner ✕; and the dialog stayed open over a new mark.
final class WatchConfirmationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Clear asks first, with the safe choice under the finger: a second tap where Clear
    /// was keeps the mark. Keep Mark keeps it too, and a new mark closes the question.
    func testClearMarkKeepsTheMarkOnASecondTap() {
        let app = startKayak(extraArguments: [
            "-uiTestActionButton", "YES", "-settings.actionButton.kayak", "manOverboard",
        ])
        goToPage(1, app)
        app.buttons["control.mob"].tap()
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        XCTAssertEqual(clear.label, "Clear")

        // The safe choice covers the opening button; the destructive one is above it.
        scrollTo(clear, in: app)
        let opener = clear.frame
        let finger = center(of: clear)
        clear.tap()
        let keep = app.buttons["mob.clearKeep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        let confirm = app.buttons["mob.clearConfirm"]
        XCTAssertEqual(app.staticTexts["confirmation.title"].label, "Clear this MOB mark?")
        XCTAssertEqual(
            app.staticTexts["confirmation.message"].label, "The arrow stops showing the way back to it.")
        XCTAssertEqual(keep.label, "Keep Mark")
        XCTAssertEqual(confirm.label, "Clear Mark")
        attachScreenshot("clear mark confirmation")
        assertSafeUnderFinger(keep: keep, confirm: confirm, opener: opener)

        // A second tap where Clear was answers "Keep Mark".
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: finger.x, dy: finger.y)).tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["mob.distance"].exists, "the mark is kept")

        // A new mark (the Action button works over the question) closes it, rather than
        // leaving it over the new arrow.
        clear.tap()
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        app.buttons["debug.actionButtonOverConfirmation"].tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10), "the question closes for a new mark")
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))

        // With two marks, the message says what happens next.
        clear.tap()
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts["confirmation.message"].label,
            "The arrow stops showing the way back to it. The next mark becomes the target.")
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10))

        endWatchSession(app, controlsPage: 2)
        clearManOverboardMark(app)
        XCTAssertTrue(app.buttons["mob.clear"].waitForExistence(timeout: 10), "the first mark is still there")
        clearManOverboardMark(app)
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    /// End asks first, with Keep Going under the finger.
    func testEndKeepsGoingOnASecondTap() {
        let app = startKayak()
        goToPage(1, app)
        let end = app.buttons["control.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        scrollTo(end, in: app)
        let opener = end.frame
        let finger = center(of: end)
        end.tap()
        let keep = app.buttons["control.endKeep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        let confirm = app.buttons["control.endConfirm"]
        XCTAssertEqual(app.staticTexts["confirmation.title"].label, "End session?")
        XCTAssertEqual(keep.label, "Keep Going")
        XCTAssertEqual(confirm.label, "End")
        attachScreenshot("end session confirmation")
        assertSafeUnderFinger(keep: keep, confirm: confirm, opener: opener)

        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: finger.x, dy: finger.y)).tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
        XCTAssertTrue(end.waitForExistence(timeout: 10), "still recording")
        XCTAssertFalse(app.buttons["summary.done"].exists)

        endWatchSession(app)
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    /// A press still waiting for a position is cancelled, not "cleared": its own words, and
    /// Keep Waiting under the finger.
    func testWaitingPressAsksToCancel() {
        let app = launchDemoApp(extraArguments: ["-uiTestManOverboardPress", "-demoLocationIssue", "unavailable"])
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["mob.waiting"].exists)
        XCTAssertEqual(clear.label, "Cancel Press")
        scrollTo(clear, in: app)
        let opener = clear.frame
        let finger = center(of: clear)
        clear.tap()
        let keep = app.buttons["mob.clearKeep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        let confirm = app.buttons["mob.clearConfirm"]
        XCTAssertEqual(app.staticTexts["confirmation.title"].label, "Cancel this MOB press?")
        XCTAssertEqual(app.staticTexts["confirmation.message"].label, "No position yet, so no mark is set.")
        XCTAssertEqual(keep.label, "Keep Waiting")
        XCTAssertEqual(confirm.label, "Cancel Press")
        attachScreenshot("cancel press confirmation")
        assertSafeUnderFinger(keep: keep, confirm: confirm, opener: opener)
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["mob.waiting"].exists, "still waiting")

        clear.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    /// At the largest accessibility text size, every part of each question can be reached
    /// (it scrolls) and both choices can be tapped.
    func testConfirmationsAtLargestTextSize() {
        let app = startKayak(extraArguments: ["-uiTestLargestText"])
        goToPage(1, app)
        let mob = app.buttons["control.mob"]
        XCTAssertTrue(mob.waitForExistence(timeout: 10))
        scrollTo(mob, in: app)
        mob.tap()
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        scrollTo(clear, in: app)
        let opener = clear.frame
        let finger = center(of: clear)
        clear.tap()
        let keep = app.buttons["mob.clearKeep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        // Too tall to fit around the finger: either Keep Mark is still under it, or nothing is,
        // and Clear Mark is clear of every point of Clear.
        let confirm = app.buttons["mob.clearConfirm"]
        assertDestructiveClear(of: opener, confirm: confirm)
        XCTAssertTrue(keep.frame.contains(finger) || confirm.frame.minY > opener.maxY)
        XCTAssertTrue(app.staticTexts["confirmation.title"].isHittable, "the title shows first")
        attachScreenshot("clear mark confirmation, largest text")
        scrollTo(keep, in: app)
        XCTAssertTrue(confirm.exists)
        attachScreenshot("clear mark confirmation, largest text, scrolled")
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 10))

        goToPage(2, app)
        let end = app.buttons["control.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        scrollTo(end, in: app)
        let endOpener = end.frame
        end.tap()
        let endKeep = app.buttons["control.endKeep"]
        XCTAssertTrue(endKeep.waitForExistence(timeout: 10))
        let endConfirm = app.buttons["control.endConfirm"]
        assertDestructiveClear(of: endOpener, confirm: endConfirm)
        let endFinger = CGPoint(x: endOpener.midX, y: endOpener.midY)
        XCTAssertTrue(endKeep.frame.contains(endFinger) || endConfirm.frame.minY > endOpener.maxY)
        attachScreenshot("end session confirmation, largest text")
        scrollTo(endConfirm, in: app)
        endConfirm.tap()
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        scrollTo(done, in: app)
        done.tap()
        clearManOverboardMark(app)
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    // MARK: - Helpers

    private func startKayak(extraArguments: [String] = []) -> XCUIApplication {
        let app = launchDemoApp(extraArguments: extraArguments)
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        scrollTo(kayak, in: app)
        kayak.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))
        return app
    }

    private func center(of element: XCUIElement) -> CGPoint {
        CGPoint(x: element.frame.midX, y: element.frame.midY)
    }

    /// The safe button covers the opening button's center, and the destructive one is above
    /// it, clear of every point of the opening button.
    private func assertSafeUnderFinger(
        keep: XCUIElement, confirm: XCUIElement, opener: CGRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        let finger = CGPoint(x: opener.midX, y: opener.midY)
        XCTAssertTrue(
            keep.frame.contains(finger), "safe button \(keep.frame) does not cover the opening button at \(finger)",
            file: file, line: line)
        assertDestructiveClear(of: opener, confirm: confirm, file: file, line: line)
        XCTAssertLessThanOrEqual(confirm.frame.maxY, keep.frame.minY, "destructive above safe", file: file, line: line)
        XCTAssertTrue(keep.isHittable, file: file, line: line)
        XCTAssertTrue(confirm.isHittable, file: file, line: line)
    }

    /// No tap that could open the confirmation (anywhere on the opening button) can land on
    /// its destructive button.
    private func assertDestructiveClear(
        of opener: CGRect, confirm: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            confirm.frame.intersects(opener),
            "destructive button \(confirm.frame) overlaps the opening button \(opener)", file: file, line: line)
    }
}
