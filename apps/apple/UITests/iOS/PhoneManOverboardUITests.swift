import XCTest

/// Man-overboard on the iPhone (docs/PLAN.md §5, Phase 2 task 6): hold to mark, the way
/// back, the mark kept across a relaunch until cleared, and a mark made on the watch.
final class PhoneManOverboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHoldToMarkShowsTheWayBackAndSurvivesRelaunch() {
        let app = launchDemoApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-app.appearance", "light",
        ])
        startKayak(app)

        // A tap is not enough: MOB needs a hold, so a stray touch cannot mark.
        let mob = element("control.mob", in: app)
        XCTAssertTrue(mob.exists)
        XCTAssertGreaterThanOrEqual(mob.frame.height, 44)
        attachScreenshot("1 controls with MOB")
        mob.tap()
        let screen = element("mob.screen", in: app)
        XCTAssertFalse(screen.waitForExistence(timeout: 2))

        mob.press(forDuration: 1.2)
        let distance = app.staticTexts["mob.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        // The demo boat heads east at 2.5 m/s: the mark falls behind, and the arrow follows
        // the course.
        waitForLabel(app.staticTexts["mob.arrowMode"], "Arrow relative to your course")
        XCTAssertTrue(app.staticTexts["mob.bearing"].label.hasPrefix("Bearing 27"))
        XCTAssertTrue(element("mob.map", in: app).exists)
        XCTAssertTrue(app.staticTexts["label.notForNavigation"].exists)
        attachScreenshot("2 man overboard light")

        // Back on the session: the card and the map keep the mark in view.
        app.buttons["mob.done"].tap()
        let card = app.buttons["mob.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["control.pause"].exists)
        attachScreenshot("3 session with MOB card")
        // With a mark set, the control shows the way back instead of moving the mark.
        mob.tap()
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        app.buttons["mob.done"].tap()

        // The mark survives the app being closed mid-session.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        let relaunched = launchDemoApp(
            extraArguments: [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-app.appearance", "light",
            ], resetSettings: false)
        XCTAssertTrue(element("mob.screen", in: relaunched).waitForExistence(timeout: 15))
        // The demo build uses no real location, so with no session there is no position.
        XCTAssertTrue(relaunched.staticTexts["mob.waiting"].exists)
        XCTAssertTrue(relaunched.buttons["mob.newSession"].exists)
        attachScreenshot("4 relaunched")

        clearMark(relaunched)
        XCTAssertTrue(relaunched.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }

    func testLargestTextDarkKeepsMOBReachable() {
        let app = launchDemoApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-app.appearance", "dark",
        ])
        startKayak(app)
        let mob = element("control.mob", in: app)
        let pause = app.buttons["control.pause"]
        XCTAssertTrue(mob.isHittable)
        XCTAssertTrue(pause.isHittable)
        attachScreenshot("5 controls largest text dark")

        mob.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        attachScreenshot("6 man overboard largest text dark")

        // Clearing from the session returns to it with no mark.
        clearMark(app)
        XCTAssertTrue(element("mob.screen", in: app).waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["mob.card"].exists)
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        attachScreenshot("7 cleared")
        endSession(app)
    }

    /// A mark made on the watch during a mirrored session shows on the phone: the demo
    /// mirror carries a mark 150 m north of the demo origin.
    func testWatchMarkShowsOnThePhone() {
        let app = launchDemoApp(extraArguments: ["-demoWatchMirror", "-demoWatchMOB", "-app.appearance", "dark"])
        startKayak(app, waitForSpeed: false)
        let distance = app.staticTexts["mob.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 15))
        attachScreenshot("8 watch mark dark")
        app.buttons["mob.done"].tap()
        XCTAssertTrue(app.buttons["mob.card"].waitForExistence(timeout: 5))
        app.buttons["mob.card"].tap()
        clearMark(app)
        XCTAssertTrue(app.buttons["control.pause"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["mob.card"].exists)
    }

    private func startKayak(_ app: XCUIApplication, waitForSpeed: Bool = true) {
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        scrollTo(kayak, in: app)
        kayak.tap()
        XCTAssertTrue(app.buttons["control.pause"].waitForExistence(timeout: 15))
        if waitForSpeed {
            waitForMetricValue(element("metric.speed", in: app), "9.0 kilometers per hour")
        }
    }

    private func clearMark(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let clear = app.buttons["mob.clear"]
        if !clear.isHittable { scrollTo(clear, in: app, file: file, line: line) }
        clear.tap()
        // SwiftUI exposes the dialog's button twice (nested); either one confirms.
        let confirm = app.buttons.matching(identifier: "mob.confirmClear").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), file: file, line: line)
        confirm.tap()
    }
}
