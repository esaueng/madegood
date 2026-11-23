import XCTest

/// A demo windsurfing session on the watch: the speed bests page between the metrics and
/// the map, and the categories in the summary. The demo board moves at a steady 8 m/s, so
/// 100 m takes 12.5 s and every filled category shows the same speed.
final class WatchWindsurfUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSpeedBestsPage() {
        let app = launchDemoApp()
        let windsurfing = app.buttons["sport.windsurfing"]
        XCTAssertTrue(windsurfing.waitForExistence(timeout: 15))
        scrollTo(windsurfing, in: app)
        windsurfing.tap()

        let speed = app.staticTexts["metric.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        waitForLabel(speed, "15.6 kn")

        // Pages: controls, metrics, speed bests, map.
        goToPage(3, app)
        XCTAssertTrue(element("page.speed", in: app).waitForExistence(timeout: 10))
        let hundred = element("speed.100m", in: app)
        let tenSeconds = element("speed.10s", in: app)
        waitForValue(hundred, "15.6 kn", timeout: 40)
        XCTAssertEqual(tenSeconds.value as? String, "15.6 kn")
        // The demo runs in a straight line and is too short for these.
        XCTAssertEqual(element("speed.nm", in: app).value as? String, "–")
        XCTAssertEqual(element("speed.alpha500", in: app).value as? String, "–")
        attachScreenshot("1 speed bests")

        goToPage(4, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        goToPage(1, app)
        app.buttons["control.end"].tap()
        let confirm = app.buttons["control.endConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        let summaryHundred = app.staticTexts["field.100 m"]
        scrollTo(summaryHundred, in: app)
        XCTAssertEqual(summaryHundred.label, "15.6 kn")
        attachScreenshot("2 summary")
        scrollTo(done, in: app)
        done.tap()
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never showed \(value); last value: \(String(describing: element.value))")
    }
}
