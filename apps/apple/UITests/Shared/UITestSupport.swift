import XCTest

extension XCTestCase {
    /// Launches the app with the synthetic demo session (DemoFeed in the app), so tests
    /// need no GPS, Health or permission prompts and see the same numbers every run.
    /// Settings start from their defaults unless `resetSettings` is false. A
    /// `-settings.<key> <value>` argument pins that setting for the launch.
    func launchDemoApp(extraArguments: [String] = [], resetSettings: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoSession"] + (resetSettings ? ["-resetSettings"] : []) + extraArguments
        app.launch()
        return app
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
