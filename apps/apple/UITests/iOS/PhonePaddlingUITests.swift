import XCTest

/// The paddling sport page on the iPhone: live stroke rate and count from the demo's
/// synthetic wrist motion, and the stroke section of a recorded kayak session.
final class PhonePaddlingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLiveStrokes() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "light"])
        let start = app.buttons["sport.kayak"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()

        // The demo paddles at 64 SPM, two strokes per wrist cycle.
        let rate = element("metric.strokeRate", in: app)
        XCTAssertTrue(rate.waitForExistence(timeout: 15))
        XCTAssertEqual(rate.label, "Stroke rate")
        let predicate = NSPredicate(format: "value MATCHES %@", "6[2-6] strokes per minute")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: rate)], timeout: 30),
            .completed, "stroke rate never settled; last value: \(rate.value ?? "missing")")
        let strokes = element("metric.strokes", in: app)
        XCTAssertGreaterThan(Int(strokes.value as? String ?? "") ?? 0, 0)
        let perStroke = element("metric.distancePerStroke", in: app)
        XCTAssertTrue((perStroke.value as? String)?.hasSuffix(" meters") == true)
        // Strokes sit below the regular metrics and above the pinned controls.
        XCTAssertLessThan(element("metric.time", in: app).frame.maxY, rate.frame.minY)
        XCTAssertLessThan(rate.frame.maxY, app.buttons["control.lap"].frame.minY)
        // A fresh simulator asks for location for the live map; answer so the card is visible.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.exists { allow.tap() }
        attachScreenshot("paddling live")

        endSession(app)
        XCTAssertTrue(start.waitForExistence(timeout: 20))
    }

    func testSessionDetailStrokes() {
        for appearance in ["light", "dark"] {
            let app = launchDemoHistory(extraArguments: ["-app.appearance", appearance])
            app.tabBars.buttons["History"].tap()
            let rows = app.buttons.matching(identifier: "session.row")
            let kayak = rows.containing(.staticText, identifier: "Kayak").firstMatch
            XCTAssertTrue(kayak.waitForExistence(timeout: 15))
            scrollTo(kayak, in: app)
            kayak.tap()

            let chart = element("chart.strokeRate", in: app)
            XCTAssertTrue(element("replay.map", in: app).waitForExistence(timeout: 20))
            scrollTo(chart, in: app)
            let count = app.staticTexts["stat.Strokes"]
            XCTAssertTrue(count.exists)
            // About 66 SPM for 15 minutes and 72 SPM for 18: over 2,000 strokes.
            XCTAssertGreaterThan(Int(count.label) ?? 0, 2_000)
            let average = app.staticTexts["stat.Avg stroke rate"].label
            XCTAssertTrue(average.hasSuffix(" spm"), average)
            let value = Int(average.split(separator: " ").first ?? "") ?? 0
            XCTAssertTrue((66...72).contains(value), average)
            XCTAssertTrue(app.staticTexts["stat.Per stroke"].label.hasSuffix(" m"))
            // Kayak has no paddling side.
            XCTAssertFalse(app.staticTexts["stat.Side switches"].exists)
            attachScreenshot("\(appearance) detail strokes")
            app.terminate()
        }
    }
}
