import XCTest

@MainActor
final class PhoneAnchorAlarmUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testArmAndDisarmAfterDrift() {
        let app = launchDemoApp(extraArguments: [
            "-demoAnchorDrift", "-settings.distanceUnit.motorboating", "m",
        ])
        let open = app.buttons["anchor.open"]
        scrollTo(open, in: app)
        open.tap()

        let picker = app.buttons["anchor.radius"]
        scrollTo(picker, in: app)
        picker.tap()
        let radiusLabel = "20.0 m"
        let radius = app.buttons[radiusLabel]
        XCTAssertTrue(radius.waitForExistence(timeout: 5))
        radius.tap()

        let arm = app.buttons["anchor.arm"]
        scrollTo(arm, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: arm)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        arm.tap()

        let status = app.staticTexts["anchor.status"]
        waitForLabel(status, "Armed", timeout: 10)
        let armedRadius = element("anchor.armedRadius", in: app)
        XCTAssertTrue(armedRadius.exists)
        XCTAssertTrue(
            armedRadius.value as? String == radiusLabel || armedRadius.label.contains(radiusLabel),
            "Expected armed radius \(radiusLabel), found \(armedRadius)")
        XCTAssertTrue(element("anchor.distance", in: app).exists)
        XCTAssertTrue(element("anchor.bearing", in: app).exists)
        XCTAssertTrue(element("anchor.accuracy", in: app).exists)

        app.navigationBars.buttons.firstMatch.tap()
        let banner = app.buttons["anchor.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        waitForLabel(banner, "Anchor dragging", timeout: 30)
        XCTAssertTrue(banner.isHittable)
        banner.tap()

        let stop = app.buttons["anchor.stopDrift"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        waitForLabel(status, "Armed", timeout: 5)

        let disarm = app.buttons["anchor.disarm"]
        scrollTo(disarm, in: app)
        disarm.tap()
        app.buttons["anchor.confirmDisarm"].firstMatch.tap()
        waitForLabel(status, "Alarm off", timeout: 5)
        XCTAssertFalse(banner.exists)
    }

    func testArmsFromLiveMotorboatRecording() {
        let app = launchDemoApp()
        let start = app.buttons["sport.motorboating"]
        scrollTo(start, in: app)
        start.tap()
        let recording = element("recordingBadge", in: app)
        XCTAssertTrue(recording.waitForExistence(timeout: 15))
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        let open = app.buttons["anchor.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let arm = app.buttons["anchor.arm"]
        scrollTo(arm, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: arm)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        arm.tap()
        waitForLabel(app.staticTexts["anchor.status"], "Armed", timeout: 10)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["anchor.banner"].exists)
        endSession(app)
    }
}
