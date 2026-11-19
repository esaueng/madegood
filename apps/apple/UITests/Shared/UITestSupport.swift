import XCTest

extension XCTestCase {
    /// Launches the app with the synthetic demo session (DemoFeed in the app), so tests
    /// need no GPS, Health or permission prompts and see the same numbers every run.
    /// Settings start from their defaults, with no man-overboard mark, unless
    /// `resetSettings` is false (a relaunch that keeps them). A `-settings.<key> <value>`
    /// argument pins that setting for the launch.
    func launchDemoApp(extraArguments: [String] = [], resetSettings: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-demoSession"] + (resetSettings ? ["-resetSettings", "-resetManOverboard"] : []) + extraArguments
        app.launch()
        return app
    }

    /// An independent synthetic library for each test, preserved across that test's relaunches.
    func launchDemoHistory(extraArguments: [String] = []) -> XCUIApplication {
        launchDemoApp(
            extraArguments: ["-demoHistory", "-demoHistoryNamespace", UUID().uuidString] + extraArguments)
    }

    /// Ends an iPhone recording the way a user does: Pause, then Save.
    func endSession(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["control.pause"].tap()
        let save = app.buttons["control.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), file: file, line: line)
        save.tap()
    }

    /// Saves a screenshot in the test results (export with `xcrun xcresulttool`).
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Any element with this accessibility identifier.
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Swipes up until the element can be tapped.
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            // A slow drag, like a finger: the watch ignores XCUITest's quick swipes.
            let window = app.windows.firstMatch
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            low.press(forDuration: 0.05, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.isHittable, "\(element) never became hittable", file: file, line: line)
    }

    /// Waits until the element's label equals `label`.
    func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never showed \(label); last label: \(element.exists ? element.label : "missing")")
    }
}
