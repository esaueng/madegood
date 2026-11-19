import XCTest

/// The start line on the iPhone's sailing countdown, with the demo's fixed ends (see
/// WatchStartLineUITests): ping both ends, read distance, time to the line, time to burn
/// and the favoured end, and get the OCS warning when over at the gun.
final class PhoneStartLineUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPingBothEndsShowsDistanceTimeAndBias() {
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.sailing", "1", "-demoCountdownSeconds", "240", "-app.appearance", "light",
        ])
        startSailing(app)
        pingBothEnds(app)
        let distance = element("startLine.distance", in: app)
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        waitFor(distance, label: "[0-9]+ m to line", timeout: 10)
        waitFor(element("startLine.timeToLine", in: app), label: "To line [0-9]:[0-9]{2}", timeout: 10)
        waitFor(element("startLine.burn", in: app), label: "Late −0:0[2-4]", timeout: 10)
        let bias = element("startLine.bias", in: app)
        scrollTo(bias, in: app)
        XCTAssertEqual(bias.label, "Boat end favoured by 6 degrees")
        XCTAssertTrue(element("startLine.notForNavigation", in: app).exists)
        attachScreenshot("1 start line")
        // Sync is unchanged.
        let sync = app.buttons["countdown.sync"]
        scrollTo(sync, in: app)
        sync.tap()
        app.buttons["countdown.cancel"].tap()
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOverTheLineAtTheGunWarnsOCS() {
        let app = launchDemoApp(extraArguments: [
            "-settings.countdown.sailing", "1", "-demoCountdownSeconds", "40", "-demoOCS", "-app.appearance", "dark",
        ])
        startSailing(app)
        pingBothEnds(app)
        waitFor(element("startLine.burn", in: app), label: "Burn 0:0[4-6]", timeout: 10)
        attachScreenshot("2 start line early")
        let banner = element("ocs.banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 60))
        attachScreenshot("3 OCS")
        app.buttons["ocs.dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        endSession(app)
    }

    private func startSailing(_ app: XCUIApplication) {
        let start = app.buttons["sport.sailing"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        scrollTo(start, in: app)
        start.tap()
        XCTAssertTrue(element("countdown.time", in: app).waitForExistence(timeout: 10))
    }

    private func pingBothEnds(_ app: XCUIApplication) {
        for end in ["pin", "boat"] {
            let button = app.buttons["startLine.ping.\(end)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            scrollTo(button, in: app)
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
