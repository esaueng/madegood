import XCTest

/// Records a demo kayak session on the iPhone: start card, live metrics, pause and resume,
/// lap, stop.
final class PhoneSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoSession() {
        let app = launchDemoApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-app.appearance", "light",
        ])

        // Tapping a sport card starts it (no countdown by default).
        let start = app.buttons["sport.kayak"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        reveal(start, above: app.tabBars.firstMatch, in: app)
        attachScreenshot("1 home")
        start.tap()

        let speed = element("metric.speed", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 15))
        XCTAssertEqual(speed.label, "Speed")
        waitForMetricValue(speed, "9.0 kilometers per hour")
        let time = element("metric.time", in: app)
        let distance = element("metric.distance", in: app)
        let heartRate = element("metric.heartRate", in: app)
        let lap = app.buttons["control.lap"]
        XCTAssertEqual(time.frame.minY, distance.frame.minY, accuracy: 2)
        XCTAssertEqual(time.frame.minY, heartRate.frame.minY, accuracy: 2)
        XCTAssertLessThan(heartRate.frame.maxY, lap.frame.minY)
        XCTAssertEqual(element("recordingBadge", in: app).label, "Recording")
        attachScreenshot("2 recording")

        // The Live Activity: leave the app and look at the Dynamic Island and Lock Screen.
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        _ = springboard.wait(for: .runningForeground, timeout: 5)
        sleep(6)  // let an update with live numbers arrive
        attachScreenshot("2b live activity")
        app.activate()
        XCTAssertTrue(speed.waitForExistence(timeout: 10))

        // Recording shows no way to end; pausing shows Resume and Save.
        XCTAssertFalse(app.buttons["control.save"].exists)
        app.buttons["control.pause"].tap()
        let pauseBadge = element("pauseBadge", in: app)
        XCTAssertTrue(pauseBadge.waitForExistence(timeout: 10))
        XCTAssertEqual(pauseBadge.label, "Paused")
        XCTAssertTrue(app.buttons["control.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["control.lap"].exists)
        attachScreenshot("3 paused")
        app.buttons["control.pause"].tap()
        XCTAssertTrue(pauseBadge.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["control.save"].waitForNonExistence(timeout: 5))
        app.buttons["control.lap"].tap()
        waitForLabel(app.staticTexts["metric.lap"], "Lap 2")
        attachScreenshot("4 lap")

        app.buttons["control.mark"].tap()
        let sensors = app.buttons["Sensors"]
        reveal(sensors, above: lap, in: app)
        sensors.tap()
        let marks = app.staticTexts["Marks 1"]
        reveal(marks, above: lap, in: app)

        endSession(app)
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        attachScreenshot("5 stopped")
    }

    func testLargestTextKeepsSelectedMetricAndControlsReadable() {
        let app = launchDemoApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-app.appearance", "dark",
            "-settings.firstScreen.sailing", "distance",
            "-settings.speedUnit.sailing", "mph",
            "-settings.distanceUnit.sailing", "mi",
        ])
        let sailing = app.buttons["sport.sailing"]
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()

        let distance = element("metric.distance", in: app)
        let speed = element("metric.speed", in: app)
        let time = element("metric.time", in: app)
        let course = element("metric.course", in: app)
        XCTAssertTrue(distance.waitForExistence(timeout: 15))
        XCTAssertEqual(distance.label, "Distance")
        XCTAssertTrue((distance.value as? String)?.hasSuffix(" miles") == true)
        waitForMetricValue(speed, "5.6 miles per hour")
        waitForMetricValue(course, "90 degrees true")
        XCTAssertEqual(time.label, "Elapsed time")
        XCTAssertLessThan(distance.frame.maxY, speed.frame.minY)
        XCTAssertLessThan(speed.frame.maxY, time.frame.minY)
        XCTAssertLessThan(time.frame.maxY, course.frame.minY)
        XCTAssertFalse(element("metric.heartRate", in: app).exists)
        let pause = app.buttons["control.pause"]
        let lap = app.buttons["control.lap"]
        XCTAssertLessThanOrEqual(speed.frame.maxY, lap.frame.minY)
        XCTAssertTrue(lap.isHittable)
        XCTAssertTrue(app.buttons["control.mark"].isHittable)
        XCTAssertTrue(pause.isHittable)
        attachScreenshot("large text distance first")

        reveal(course, above: lap, in: app)
        attachScreenshot("large text supporting metrics")
        let moreMetrics = app.buttons["More metrics"]
        reveal(moreMetrics, above: lap, in: app)
        moreMetrics.tap()
        XCTAssertTrue(element("metric.heartRate", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(pause.isHittable)

        pause.tap()
        let save = app.buttons["control.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(pause.isHittable)
        attachScreenshot("large text paused")
        save.tap()
        XCTAssertTrue(sailing.waitForExistence(timeout: 20))
    }

    /// SwiftUI can report a scroll view child as hittable while the pinned controls cover it.
    private func reveal(
        _ element: XCUIElement, above control: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<6 where !element.exists || element.frame.maxY > control.frame.minY - 12 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.51))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, control.frame.minY, file: file, line: line)
    }
}

extension XCTestCase {
    func waitForMetricValue(_ element: XCUIElement, _ value: String) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 15), .completed,
            "\(element) never showed \(value); last value: \(element.value ?? "missing")")
    }
}
