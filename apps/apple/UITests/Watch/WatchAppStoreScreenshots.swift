import XCTest

/// The Apple Watch App Store screenshot set, from the synthetic demo session (`-demoSession`
/// with `-demoTacks`: a beat with the wind from north). `scripts/app-store-screenshots` runs
/// this class on the largest watch simulator and exports the attachments named
/// `appstore NN-name`; CI runs it too, so the tour keeps working as the screens change.
/// watchOS simulators have no status bar override, so the clock shows the time of the run.
final class WatchAppStoreScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSailingSession() {
        let app = launchDemoApp(extraArguments: ["-demoTacks"])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sleep(1)
        attachAppStoreScreenshot("01-sports")
        sailing.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))

        // Pages: controls, metrics, sailing, map. Wait for the wind estimate first, so
        // every page shows a session well under way.
        goToPage(3, app)
        XCTAssertTrue(element("page.sailing", in: app).waitForExistence(timeout: 10))
        let wind = app.staticTexts["field.Wind axis"]
        wait(for: wind, label: "(00[0-5]|35[5-9])°/(17[5-9]|18[0-5])°", timeout: 150)
        wait(for: app.staticTexts["field.Tacks/gybes"], label: "[1-9][0-9]*", timeout: 30)
        sleep(2)
        attachAppStoreScreenshot("03-sailing")
        goToPage(2, app)
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 10))
        sleep(2)
        attachAppStoreScreenshot("02-metrics")
        goToPage(4, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        sleep(3)  // map tiles
        attachAppStoreScreenshot("04-map")

        goToPage(1, app)
        app.buttons["control.end"].tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'End' AND identifier != 'control.end'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        sleep(1)
        attachAppStoreScreenshot("05-summary")
        scrollTo(done, in: app)
        done.tap()
    }

    private func wait(for element: XCUIElement, label pattern: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES %@", pattern), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never matched \(pattern); last label: \(element.exists ? element.label : "missing")")
    }
}
