import XCTest

/// Man-overboard on the iPhone (docs/PLAN.md §5, Phase 2 task 6): hold to mark, the way
/// back, the mark kept across a relaunch until cleared, and a mark made on the watch.
@MainActor
final class PhoneManOverboardUITests: XCTestCase {
    override func setUp() async throws {
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
        // With no session, guidance comes from the phone's own location (in the demo
        // build, a still boat at the demo origin), pointing from north.
        XCTAssertTrue(relaunched.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        waitForLabel(relaunched.staticTexts["mob.arrowMode"], "Arrow points from north")
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

    /// MOB during a countdown, before any local recording, marks from the phone's own
    /// location; after cancelling, the mark fills the Record tab. Then MOB from the start
    /// screen itself.
    func testMarkDuringACountdownAndFromTheStartScreen() {
        let app = launchDemoApp(extraArguments: ["-settings.countdown.kayak", "1", "-app.appearance", "light"])
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        scrollTo(kayak, in: app)
        kayak.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))
        let mob = element("control.mob", in: app)
        XCTAssertTrue(mob.waitForExistence(timeout: 5))
        attachScreenshot("9 countdown with MOB")
        mob.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        attachScreenshot("10 marked during countdown")
        app.buttons["mob.done"].tap()

        app.buttons["countdown.cancel"].tap()
        XCTAssertTrue(app.buttons["mob.newSession"].waitForExistence(timeout: 10))
        clearMark(app)
        XCTAssertTrue(kayak.waitForExistence(timeout: 10))

        let startMOB = element("control.mob", in: app)
        XCTAssertTrue(startMOB.waitForExistence(timeout: 5))
        attachScreenshot("11 start screen with MOB")
        startMOB.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mob.newSession"].exists)
        clearMark(app)
        XCTAssertTrue(kayak.waitForExistence(timeout: 10))
    }

    /// MOB during a mirrored watch session, with no local recording: the phone marks from
    /// its own location and keeps showing the watch's session.
    func testMarkDuringAMirroredWatchSession() {
        let app = launchDemoApp(extraArguments: ["-demoWatchMirror", "-app.appearance", "dark"])
        startKayak(app, waitForSpeed: false)
        endSession(app)
        let watchStatus = element("status.watchWorkout", in: app)
        XCTAssertTrue(watchStatus.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["control.pause"].exists)
        let mob = element("control.mob", in: app)
        XCTAssertTrue(mob.waitForExistence(timeout: 5))
        attachScreenshot("12 mirrored session with MOB")
        mob.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        attachScreenshot("13 marked during mirrored session")
        app.buttons["mob.done"].tap()
        XCTAssertTrue(app.buttons["mob.card"].waitForExistence(timeout: 5))
        XCTAssertTrue(watchStatus.exists)
        app.buttons["mob.card"].tap()
        clearMark(app)
        XCTAssertTrue(app.buttons["mob.card"].waitForNonExistence(timeout: 10))
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
