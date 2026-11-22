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
        launchFresh(app)
        return app
    }

    /// Launches `app` in a new process with this test's arguments and environment. On iOS,
    /// the system can start the app on its own: after a voyage test terminates it during a leg,
    /// Core Location relaunches it in the background. XCUITest did not launch that copy, so
    /// `launch()` does not terminate it and the test ends up driving a process without its
    /// arguments (no demo mode, the real voyage library). Terminate any running copy first.
    func launchFresh(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        #if os(iOS)
            if app.state != .notRunning { terminateAndSettle(app, file: file, line: line) }
        #endif
        // On watchOS, let XCTest coordinate termination and launch with the simulator.
        app.launch()
    }

    /// Terminates `app` and makes sure it stays stopped: if the system starts it again
    /// within two seconds (see `launchFresh`), terminates that copy too.
    func terminateAndSettle(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            if app.state != .notRunning {
                app.terminate()
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App still running", file: file, line: line)
            }
            let restarted = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "state != %@", NSNumber(value: XCUIApplication.State.notRunning.rawValue)),
                object: app)
            if XCTWaiter().wait(for: [restarted], timeout: 2) != .completed { return }
        }
        XCTFail("The system kept starting the app", file: file, line: line)
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

    /// Saves an App Store screenshot, named `appstore <name>` so
    /// `scripts/app-store-screenshots` can pick it out of the test results.
    func attachAppStoreScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot(), quality: .original)
        attachment.name = "appstore \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Any element with this accessibility identifier.
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Saves a screenshot and the app's element tree in the test results, kept even when
    /// the test passes, so a timeout that does not reproduce can still be diagnosed.
    func attachDiagnostics(_ name: String, app: XCUIApplication) {
        attachScreenshot("\(name) screenshot")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) element tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// Scrolls until the element is vertically inside the window and can be tapped, dragging
    /// up or down depending on where its frame is (a drag can overshoot on a small screen,
    /// like the 40 mm watch). `column` is where across the window the drags run (0...1):
    /// pass a side margin when an interactive map can sit mid-screen, or the drags pan the
    /// map instead of scrolling.
    func scrollTo(
        _ element: XCUIElement, in app: XCUIApplication, column: CGFloat = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        // An element can exist before it has a usable frame (a lazy row still off screen, or
        // a slow simulator mid-layout); asking for hittability then fails the test, so
        // check the frame first. An element taller than the window only has to overlap it.
        func frame() -> CGRect? {
            guard element.exists else { return nil }
            let frame = element.frame
            return frame.isEmpty ? nil : frame
        }
        func reachable() -> Bool {
            guard let frame = frame() else { return false }
            let bounds = window.frame
            let vertical =
                frame.height > bounds.height
                ? frame.minY < bounds.maxY && frame.maxY > bounds.minY
                : frame.minY >= bounds.minY && frame.maxY <= bounds.maxY
            return vertical && bounds.intersects(frame) && element.isHittable
        }
        var dragColumn = column
        var lastFrame: CGRect?
        for _ in 0..<12 {
            if reachable() { return }
            let bounds = window.frame
            let current = frame()
            // How far the content has to move up (positive) or down (negative), in points.
            // With no frame yet, the element is further down a lazy list.
            var shift = bounds.height * 0.45
            if let current {
                if current.minY < bounds.minY {
                    shift = current.minY - bounds.minY - bounds.height * 0.1
                } else if current.maxY > bounds.maxY {
                    shift = current.maxY - bounds.maxY + bounds.height * 0.1
                } else {
                    // Inside the window but covered (a toolbar, the watch's clock): move it
                    // toward the middle.
                    shift = current.midY - bounds.midY
                }
                // A drag that moved nothing may have landed on a control: try a side margin.
                if let lastFrame, lastFrame == current { dragColumn = dragColumn == column ? 0.15 : column }
            }
            lastFrame = current
            // Short drags near the target so it does not overshoot; at most 45% of the screen.
            let distance = min(max(abs(shift) / bounds.height, 0.15), 0.45)
            // Content moves up with an upward drag in the lower part of the screen, and down
            // with a downward drag in the upper part.
            let (fromY, toY) =
                shift > 0 ? (0.6 + distance / 2, 0.6 - distance / 2) : (0.4 - distance / 2, 0.4 + distance / 2)
            // A slow drag, like a finger: the watch ignores XCUITest's quick swipes.
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: dragColumn, dy: fromY))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: dragColumn, dy: toY))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        if reachable() { return }
        attachDiagnostics("scrollTo \(element.identifier)", app: app)
        XCTFail(
            "\(element) never became fully visible and hittable; frame \(frame().map { "\($0)" } ?? "none") in window \(window.frame)",
            file: file, line: line)
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

        /// The recording tab can request location on launch. Answer that prompt if
        /// it interrupts navigation, or require the prompt when the leg starts.
        @MainActor
        func allowLocationWhileUsing(
            during startLeg: () -> Void, file: StaticString = #filePath, line: UInt = #line
        ) {
            var accepted = false
            let monitor = addUIInterruptionMonitor(withDescription: "Location permission") { alert in
                guard alert.label.hasSuffix("to use your location?") else { return false }
                let allow = alert.buttons["Allow While Using App"]
                guard allow.exists else { return false }
                allow.tap()
                accepted = true
                return true
            }
            defer { removeUIInterruptionMonitor(monitor) }
            startLeg()
            if !accepted { allowLocationWhileUsing(file: file, line: line) }
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
