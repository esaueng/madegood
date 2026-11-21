import XCTest

/// The sailing sport page on the watch. With `-demoTacks` the demo boat beats upwind
/// (wind from north, a tack every 31 s), so the wind estimate appears about a minute in.
final class WatchSailingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSailingPageShowsWindVMGAndTacks() {
        let app = launchDemoApp(extraArguments: ["-demoTacks"])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))

        // Pages: controls, metrics, sailing, map.
        goToPage(3, app)
        XCTAssertTrue(element("page.sailing", in: app).waitForExistence(timeout: 10))
        attachScreenshot("1 sailing before an estimate")
        // Only the axis is known live: both ends, and one maneuver count.
        let wind = app.staticTexts["field.Wind axis"]
        waitFor(wind, label: "(00[0-5]|35[5-9])°/(17[5-9]|18[0-5])°", timeout: 120, app: app)
        let maneuvers = app.staticTexts["field.Tacks/gybes"]
        waitFor(maneuvers, label: "[1-9][0-9]*", timeout: 30, app: app)
        XCTAssertEqual(app.staticTexts["metric.vmg"].label, "VMG")
        XCTAssertFalse(app.staticTexts["field.Tacks"].exists)
        attachScreenshot("2 sailing with wind")

        goToPage(4, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        goToPage(1, app)
        app.buttons["control.end"].tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'End' AND identifier != 'control.end'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        let tacks = app.staticTexts["field.Tacks/gybes"]
        scrollTo(tacks, in: app)
        XCTAssertNotEqual(tacks.label, "0")
        attachScreenshot("3 summary")
        scrollTo(done, in: app)
        done.tap()
    }

    /// Waits for the label to match; on a timeout, attaches a screenshot and the element
    /// tree first (QA-01: `field.Wind axis` once went missing and did not reproduce).
    private func waitFor(
        _ element: XCUIElement, label pattern: String, timeout: TimeInterval, app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES %@", pattern), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        // `element.identifier` would resolve a missing element and stop the test before the
        // attachments are saved; the query description does not.
        if result != .completed { attachDiagnostics("\(element.description) timeout", app: app) }
        XCTAssertEqual(
            result, .completed,
            "\(element) never matched \(pattern); last label: \(element.exists ? element.label : "missing")",
            file: file, line: line)
    }
}
