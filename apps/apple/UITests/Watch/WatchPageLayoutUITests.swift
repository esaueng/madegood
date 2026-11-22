import XCTest

/// Layout of the live session pages. Regression checks from QA: the vertical page dots
/// covered the right edge of the Lap button and, on the Ultra's sailing page, the wind
/// dial; and the live map showed the route without "Not for navigation".
final class WatchPageLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testControlsAndMapClearOfPageIndicator() {
        let app = launchDemoApp()
        let kayak = app.buttons["sport.kayak"]
        XCTAssertTrue(kayak.waitForExistence(timeout: 15))
        scrollTo(kayak, in: app)
        kayak.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))

        // Pages: controls, metrics, strokes, map.
        goToPage(1, app)
        let lap = app.buttons["control.lap"]
        XCTAssertTrue(lap.waitForExistence(timeout: 10))
        attachScreenshot("controls")
        assertClearOfPageIndicator(lap, in: app)
        assertClearOfPageIndicator(app.buttons["control.end"], in: app)

        goToPage(4, app)
        XCTAssertTrue(app.otherElements["page.map"].waitForExistence(timeout: 10))
        let label = app.staticTexts["map.notForNavigation"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "Not for navigation")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(label.frame), "label off screen: \(label.frame)")
        attachScreenshot("map")
        assertClearOfPageIndicator(label, in: app)

        endWatchSession(app)
    }

    /// With `-demoTacks` the wind estimate, and so the dial, appears about a minute in.
    func testSailingPageClearOfPageIndicator() {
        let app = launchDemoApp(extraArguments: ["-demoTacks"])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()
        XCTAssertTrue(app.staticTexts["metric.speed"].waitForExistence(timeout: 15))

        // Pages: controls, metrics, sailing, map.
        goToPage(3, app)
        XCTAssertTrue(element("page.sailing", in: app).waitForExistence(timeout: 10))
        let axis = app.staticTexts["field.Wind axis"]
        let estimated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '°'"), object: axis)
        XCTAssertEqual(XCTWaiter().wait(for: [estimated], timeout: 120), .completed, "no wind estimate")
        attachScreenshot("sailing")
        // The whole page, which holds the dial at its top right.
        assertClearOfPageIndicator(app.otherElements["sailing.content"], in: app)
        assertClearOfPageIndicator(app.staticTexts["field.Heading"], in: app)

        endWatchSession(app)
    }

    /// The page dots (the element whose value is "page N of M") sit on the right edge; the
    /// element must end at least 2 pt to their left.
    private func assertClearOfPageIndicator(
        _ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let indicator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH 'page '")).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing", file: file, line: line)
        XCTAssertTrue(indicator.exists, "no page indicator", file: file, line: line)
        let dots = indicator.frame
        // Guard the assumption that the indicator's frame is the dots, not the whole page.
        XCTAssertLessThan(dots.width, 20, "indicator frame \(dots)", file: file, line: line)
        XCTAssertLessThanOrEqual(
            element.frame.maxX, dots.minX - 2,
            "\(element.identifier) \(element.frame) runs into the page dots \(dots)", file: file, line: line)
    }
}
