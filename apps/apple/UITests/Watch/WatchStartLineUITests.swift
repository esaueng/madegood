import XCTest

/// The start line on the watch's sailing countdown. The demo pings fixed ends (a 200 m
/// line, boat end 6° favoured to the demo wind from north) and the demo boat sails square
/// at it, reaching it 3 s after the gun, or 5 s before with `-demoOCS`.
final class WatchStartLineUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPingBothEndsShowsDistanceTimeAndBias() {
        let app = launchDemoApp(extraArguments: ["-settings.countdown.sailing", "1", "-demoCountdownSeconds", "240"])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))

        // Page 2 of the countdown: the line.
        goToPage(2, app)
        pingBothEnds(app)
        let distance = element("startLine.distance", in: app)
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        waitFor(distance, label: "[0-9]+ m to line", timeout: 10)
        waitFor(element("startLine.timeToLine", in: app), label: "To line [0-9]:[0-9]{2}", timeout: 10)
        // Square at the line at constant speed: 3 s late, give or take a tick.
        waitFor(element("startLine.burn", in: app), label: "Late −0:0[2-4]", timeout: 10)
        XCTAssertEqual(element("startLine.bias", in: app).label, "Boat end favoured by 6 degrees")
        XCTAssertTrue(element("startLine.notForNavigation", in: app).exists)
        attachScreenshot("1 start line")

        // The timer page still syncs and cancels.
        goToPage(1, app)
        XCTAssertTrue(app.buttons["countdown.sync"].waitForExistence(timeout: 5))
        attachScreenshot("2 countdown")
        app.buttons["countdown.cancel"].tap()
        XCTAssertTrue(sailing.waitForExistence(timeout: 10))
    }

    func testOverTheLineAtTheGunWarnsOCS() {
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.sailing", "1", "-demoCountdownSeconds", "40", "-demoOCS",
        ])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))
        goToPage(2, app)
        pingBothEnds(app)
        // Early: positive time to burn.
        waitFor(element("startLine.burn", in: app), label: "Burn 0:0[4-6]", timeout: 10)

        // Recording starts at the gun with the boat over the line.
        let banner = element("ocs.banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 60))
        attachScreenshot("3 OCS")
        app.buttons["ocs.dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        endWatchSession(app)
    }

    /// A ping that fails just before the gun is reported on the session pages.
    func testPingFailureNearTheGunShowsOnTheSessionPages() {
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.sailing", "1", "-demoCountdownSeconds", "18", "-demoNoPingFix",
        ])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))
        goToPage(2, app)
        let pin = app.buttons["startLine.ping.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        let banner = element("pingFailed.banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 40))
        attachScreenshot("4 ping failed at start")
        app.buttons["pingFailed.dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        endWatchSession(app)
    }

    private func pingBothEnds(_ app: XCUIApplication) {
        for end in ["pin", "boat"] {
            let button = app.buttons["startLine.ping.\(end)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            let set = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Set'"), object: button)
            XCTAssertEqual(XCTWaiter().wait(for: [set], timeout: 10), .completed, "\(end) never set")
        }
    }

    private func waitFor(_ element: XCUIElement, label pattern: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES %@", pattern), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never matched \(pattern); last label: \(element.exists ? element.label : "missing")")
    }
}
