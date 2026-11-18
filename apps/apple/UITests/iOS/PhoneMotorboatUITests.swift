import XCTest

/// The motorboat profile on iPhone: the trip log and fuel estimate on the live page and in
/// session detail, and the anchor alarm from drop to drag alarm to raise.
final class PhoneMotorboatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testMotorboatLiveLogFuelAndDetail() {
        let app = launchDemoApp(extraArguments: [
            "-app.appearance", "light",
            "-settings.fuelBurn.motorboating", "36",
        ])
        let start = app.buttons["sport.motorboating"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()

        // The demo boat runs at 2.5 m/s, above the under-way speed, so engine time and
        // the estimate grow with the session.
        let engine = element("motor.engineTime", in: app)
        XCTAssertTrue(engine.waitForExistence(timeout: 15))
        // The live map's position asks for location once on a fresh simulator.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let fuel = element("motor.fuel", in: app)
        waitForLabel(fuel, "0.1 L", timeout: 30)  // 36 L/h ≈ 0.1 L after 10 s
        XCTAssertTrue(element("motor.trip", in: app).label.hasSuffix("nm"))
        XCTAssertTrue(element("motor.log", in: app).label.hasSuffix("nm"))
        scrollTo(element("anchor.open", in: app), in: app)
        attachScreenshot("motorboat 1 live")

        endSession(app)
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        let row = app.buttons.matching(identifier: "session.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let detailFuel = element("motor.fuel", in: app)
        scrollTo(detailFuel, in: app)
        XCTAssertTrue(detailFuel.label.hasSuffix(" L"), detailFuel.label)
        XCTAssertNotEqual(element("motor.engineTime", in: app).label, "0:00")
        attachScreenshot("motorboat 2 detail")
    }

    func testFuelSettingsAreEditable() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "dark"])
        let gear = app.buttons["sportSettings.open.motorboating"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        let burn = app.textFields["sportSettings.fuelBurn"]
        scrollTo(burn, in: app)
        burn.tap()
        burn.typeText("24")
        app.textFields["sportSettings.fuelIdleBurn"].tap()
        XCTAssertEqual(burn.value as? String, "24")
        attachScreenshot("motorboat 3 fuel settings")
    }

    func testAnchorAlarmHoldsThenAlarmsWhenDragging() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "light", "-demoAnchorDrift"])
        let open = app.buttons["anchor.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertTrue(open.label.contains("Off"), open.label)
        open.tap()

        // Pick a 20 m circle, then drop the anchor once the demo position is in.
        app.buttons["anchor.radius"].tap()
        app.buttons["20 m"].tap()
        let set = app.buttons["anchor.set"]
        XCTAssertTrue(set.waitForExistence(timeout: 10))
        waitForPredicate(set, "isEnabled == true")
        set.tap()

        let status = element("anchor.status", in: app)
        XCTAssertTrue(status.label.contains("Anchor watch on"), status.label)
        XCTAssertTrue(element("anchor.distance", in: app).waitForExistence(timeout: 5))
        attachScreenshot("anchor 1 holding")

        // The demo boat drags east at 1.5 m/s from 5 s after the drop.
        let silence = app.buttons["anchor.silence"]
        XCTAssertTrue(silence.waitForExistence(timeout: 60))
        XCTAssertTrue(status.label.contains("Anchor dragging"), status.label)
        XCTAssertTrue(element("anchor.banner", in: app).exists)
        attachScreenshot("anchor 2 dragging")

        silence.tap()
        XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Anchor watch on"), status.label)

        let raise = app.buttons["anchor.raise"]
        scrollTo(raise, in: app)
        raise.tap()
        app.buttons["anchor.raise.confirm"].firstMatch.tap()
        waitForPredicate(status, "label BEGINSWITH 'No anchor set'")
        attachScreenshot("anchor 3 raised")
    }

    /// Review regression: without notification permission the watch must say so, not
    /// look fully armed.
    func testAnchorWarnsWhenNotificationsAreOff() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "dark", "-demoNotificationsDenied"])
        let open = app.buttons["anchor.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let warning = element("anchor.issue.notificationsOff", in: app)
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["anchor.openSettings"].exists)
        let set = app.buttons["anchor.set"]
        scrollTo(set, in: app)
        waitForPredicate(set, "isEnabled == true")
        set.tap()
        let status = element("anchor.status", in: app)
        waitForPredicate(status, "label BEGINSWITH 'Anchor watch limited'")
        XCTAssertTrue(warning.exists)
        attachScreenshot("anchor 4 notifications off")
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.buttons["anchor.open"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("alerts may not reach you"), row.label)
    }

    private func waitForPredicate(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, element.label)
    }
}
