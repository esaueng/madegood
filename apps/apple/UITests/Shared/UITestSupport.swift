import XCTest

extension XCTestCase {
    /// Launches the app with the synthetic demo session (DemoFeed in the app), so tests
    /// need no GPS, Health or permission prompts and see the same numbers every run.
    func launchDemoApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoSession"] + extraArguments
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

    /// Waits until the element's label equals `label`.
    func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never showed \(label); last label: \(element.exists ? element.label : "missing")")
    }
}
