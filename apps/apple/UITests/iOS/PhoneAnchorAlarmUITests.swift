import XCTest

@MainActor
final class PhoneAnchorAlarmUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testArmAndDisarmAfterDrift() {
        let app = launchDemoApp(extraArguments: ["-demoAnchorDrift"])
        let open = app.buttons["anchor.open"]
        scrollTo(open, in: app)
        open.tap()

        XCTAssertTrue(app.buttons["anchor.radius"].waitForExistence(timeout: 10))

        let arm = app.buttons["anchor.arm"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: arm)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        scrollTo(arm, in: app)
        arm.tap()

        let status = app.staticTexts["anchor.status"]
        waitForLabel(status, "Armed", timeout: 10)
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
}
