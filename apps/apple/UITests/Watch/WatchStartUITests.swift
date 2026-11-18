import XCTest

/// The watch start screen: sport cards, per-sport settings, the start countdown, the
/// first screen and the distance alert. Settings are reset at each launch.
final class WatchStartUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Sailing with a countdown that opens on distance: card → countdown (Sync rounds to
    /// the minute) → recording starts at zero on the distance screen.
    func testCountdownOpensOnFirstScreen() {
        // A 70 s countdown, so Sync has a whole minute to round to.
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.sailing", "1", "-demoCountdownSeconds", "70",
            "-settings.firstScreen.sailing", "distance",
        ])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()

        let time = element("countdown.time", in: app)
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        attachScreenshot("countdown")
        app.buttons["countdown.sync"].tap()
        // 1:08 or so rounds to 1:00 (0:59 if a second passes before the read).
        XCTAssertTrue(["60 seconds to start", "59 seconds to start"].contains(time.label), "after sync: \(time.label)")
        attachScreenshot("countdown synced")
        app.buttons["countdown.startNow"].tap()

        // The session opens on distance, with speed as a field, and its clock from zero.
        let distance = app.staticTexts["metric.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["field.Speed"].exists)
        waitForLabel(app.staticTexts["field.Speed"], "4.9 kn")
        attachScreenshot("first screen distance")
        endWatchSession(app)
        XCTAssertTrue(sailing.waitForExistence(timeout: 10))
    }

    /// The countdown runs out by itself and recording starts.
    func testCountdownStartsRecording() {
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.kayak", "1", "-demoCountdownSeconds", "4",
        ])
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        kayak.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))
        // Kayak has no Sync: that is for race starts.
        XCTAssertFalse(app.buttons["countdown.sync"].exists)
        let speed = app.staticTexts["metric.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForLabel(speed, "9.0 km/h")
        endWatchSession(app)
    }

    /// A setting changed on the watch is used by the next session and survives leaving
    /// the screen; a hidden sport leaves the start screen.
    func testSportSettingsPersistAndHide() {
        let app = launchDemoApp()
        let canoe = app.buttons["sport.canoe"]
        XCTAssertTrue(canoe.waitForExistence(timeout: 15))
        attachScreenshot("start cards")

        // Canoe opens on heart rate.
        let canoeSettings = app.buttons["sportSettings.open.canoe"]
        scrollTo(canoeSettings, in: app)
        canoeSettings.tap()
        let firstScreen = app.buttons["sportSettings.firstScreen"]
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 10))
        attachScreenshot("sport settings")
        firstScreen.tap()
        let heartRate = app.buttons["Heart rate"]
        XCTAssertTrue(heartRate.waitForExistence(timeout: 10))
        heartRate.tap()
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 10))
        XCTAssertTrue(firstScreen.label.contains("Heart rate"), "picker shows \(firstScreen.label)")
        app.swipeUp()
        attachScreenshot("sport settings lower")
        app.navigationBars.buttons.firstMatch.tap()

        // Reopening shows the saved value.
        scrollTo(canoeSettings, in: app)
        canoeSettings.tap()
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 10))
        XCTAssertTrue(firstScreen.label.contains("Heart rate"), "picker shows \(firstScreen.label)")
        app.navigationBars.buttons.firstMatch.tap()

        scrollTo(canoe, in: app)
        canoe.tap()
        XCTAssertTrue(app.staticTexts["metric.heartRate"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["field.Speed"].exists)
        attachScreenshot("first screen heart rate")
        endWatchSession(app)

        // Hide windsurfing.
        let windsurfing = app.buttons["sport.windsurfing"]
        XCTAssertTrue(windsurfing.waitForExistence(timeout: 10))
        let windsurfingSettings = app.buttons["sportSettings.open.windsurfing"]
        scrollTo(windsurfingSettings, in: app)
        windsurfingSettings.tap()
        let visible = app.switches["sportSettings.visible"]
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 10))
        scrollTo(visible, in: app)
        // Tap the switch itself, at the right of the row.
        visible.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: visible)
        XCTAssertEqual(
            XCTWaiter().wait(for: [off], timeout: 5), .completed, "toggle: \(String(describing: visible.value))")
        attachScreenshot("sport hidden")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(canoe.waitForExistence(timeout: 10))
        XCTAssertFalse(windsurfing.exists)
        // The sport just used comes first.
        XCTAssertLessThan(canoe.frame.minY, app.buttons["sport.sailing"].frame.minY)
    }

    /// The distance alert shows a banner during the session (50 m in the demo: 20 s).
    func testDistanceAlertBanner() {
        let app = launchDemoApp(extraArguments: ["-settings.distanceAlert.kayak", "0.05"])
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        kayak.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))
        let banner = element("distanceAlert.banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 45))
        XCTAssertTrue(banner.label.contains("50 m"), "banner: \(banner.label)")
        sleep(1)  // let it finish sliding in
        attachScreenshot("distance alert")
        endWatchSession(app)
    }

    /// The Action button (a stand-in, since UI tests can't press it): during a countdown a
    /// press starts recording now (kayak can't sync), then each press does the sport's
    /// action, here man-overboard, which opens the way-back page.
    func testActionButtonSkipsCountdownThenMarksManOverboard() {
        let app = launchDemoApp(extraArguments: [
            "-uiTestActionButton", "YES",
            "-settings.countdown.kayak", "1", "-demoCountdownSeconds", "60",
            "-settings.actionButton.kayak", "manOverboard",
        ])
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        kayak.tap()
        let action = app.buttons["debug.actionButton"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["metric.speed"].exists, "still counting down")
        action.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))
        action.tap()
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        attachScreenshot("action button man overboard")
        // Regression check from review: a press while a mark exists moves it and shows the
        // way back again, even from another page. MOB is page 1, so metrics is page 3.
        goToPage(3, app)
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
        // The MOB page comes first, so the controls are page 2.
        endWatchSession(app, controlsPage: 2)
        // The mark outlives the session; clear it so later tests start on the sport cards.
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertTrue(app.buttons["sport.kayak"].waitForExistence(timeout: 10))
    }
}
