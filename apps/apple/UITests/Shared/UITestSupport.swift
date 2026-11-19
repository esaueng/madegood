import XCTest

extension XCTestCase {
    /// Launches the app with the synthetic demo session (DemoFeed in the app), so tests
    /// need no GPS, Health or permission prompts and see the same numbers every run.
    /// Settings start from their defaults unless `resetSettings` is false. A
    /// `-settings.<key> <value>` argument pins that setting for the launch.
    func launchDemoApp(extraArguments: [String] = [], resetSettings: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoSession"] + (resetSettings ? ["-resetSettings"] : []) + extraArguments
        launchFresh(app)
        return app
    }

    /// Launches `app` in a new process with this test's arguments and environment. The
    /// system can start the app on its own: after a voyage test terminates it during a leg,
    /// Core Location relaunches it in the background. XCUITest did not launch that copy, so
    /// `launch()` does not terminate it and the test ends up driving a process without its
    /// arguments (no demo mode, the real voyage library). Terminate any running copy first.
    func launchFresh(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App still running", file: file, line: line)
        }
        app.launch()
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
        // An element can exist before it has a usable frame (a lazy row still off screen, or
        // a slow simulator mid-layout); asking for hittability then fails the test, so
        // scroll until its frame is inside the window first.
        func reachable() -> Bool {
            guard element.exists, !element.frame.isEmpty,
                app.windows.firstMatch.frame.intersects(element.frame)
            else { return false }
            return element.isHittable
        }
        for _ in 0..<8 where !reachable() {
            // A slow drag, like a finger: the watch ignores XCUITest's quick swipes.
            let window = app.windows.firstMatch
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            low.press(forDuration: 0.05, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(reachable(), "\(element) never became hittable", file: file, line: line)
    }

    #if os(iOS)
        /// Clears the app's location permission so a test that records positions starts from
        /// "not determined" and answers the prompt itself. Earlier tests can leave it denied:
        /// a live session's map asks for location, and when a test does not answer, XCTest's
        /// default interruption handler taps "Don't Allow". Call before `launch()`.
        func resetLocationPermission(_ app: XCUIApplication) {
            app.resetAuthorizationStatus(for: .location)
        }

        /// Answers the location prompt that a reset permission guarantees.
        func allowLocationWhileUsing(file: StaticString = #filePath, line: UInt = #line) {
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
            XCTAssertTrue(allow.waitForExistence(timeout: 10), "No location prompt", file: file, line: line)
            allow.tap()
        }
    #endif

    /// Waits until the element's label equals `label`.
    func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "\(element) never showed \(label); last label: \(element.exists ? element.label : "missing")")
    }
}
