import XCTest

/// The iPhone's confirmation cards (`ConfirmationCard`): each shows its title and what is
/// affected, and both buttons can be reached and tapped, in light, in dark and at the largest
/// text size (where the card scrolls). Backing out with the named button changes nothing.
/// The live voyage sharing card needs a local worker (`PhoneVoyageLoopbackUITests`).
@MainActor
final class PhoneConfirmationCardsUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private enum Look: String, CaseIterable {
        case light, dark
        case largestText = "largest text"

        var arguments: [String] {
            switch self {
            case .light: ["-app.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            case .dark: ["-app.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            case .largestText:
                ["-app.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
        }
    }

    func testDeleteSessionCard() {
        for look in Look.allCases {
            let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"] + look.arguments)
            app.tabBars.buttons["History"].tap()
            let rows = app.buttons.matching(identifier: "session.row")
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 15))
            // At the largest text sizes the row is a lazy one below the fold.
            let sailing = rows.containing(.staticText, identifier: "Sailing").firstMatch
            // At the largest text sizes the row is taller than the screen: bring its middle in.
            dragUntil(in: app) { sailing.exists && app.windows.firstMatch.frame.contains(sailing.frame.center) }
            sailing.swipeLeft()
            let delete = app.buttons["session.row.delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5))
            delete.tap()
            checkCard(
                "Delete this session?", confirm: "session.confirmDelete", backOut: "session.keep",
                screenshot: "delete session", look: look, in: app)
            XCTAssertTrue(sailing.exists)

            // Deleted, it waits in Recently Deleted, where deleting for good asks again.
            if !delete.exists { sailing.swipeLeft() }
            XCTAssertTrue(delete.waitForExistence(timeout: 5))
            delete.tap()
            let confirm = app.buttons["session.confirmDelete"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            if !confirm.isHittable { scrollTo(confirm, in: app) }
            confirm.tap()
            let recentlyDeleted = app.buttons["history.recentlyDeleted"]
            dragUntil(in: app) { recentlyDeleted.isHittable }
            recentlyDeleted.tap()
            let row = app.buttons.matching(identifier: "deleted.row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.swipeLeft()
            let rowDelete = app.buttons["deleted.row.delete"]
            XCTAssertTrue(rowDelete.waitForExistence(timeout: 5))
            rowDelete.tap()
            checkCard(
                "Delete this session permanently?", confirm: "deleted.confirmDelete", backOut: "deleted.keep",
                screenshot: "delete permanently", look: look, in: app)
            XCTAssertTrue(row.exists)
        }
    }

    func testManOverboardCards() {
        for look in Look.allCases {
            let app = launchDemoApp(extraArguments: ["-app.showManOverboardButton", "1"] + look.arguments)
            pressManOverboard(in: app)
            XCTAssertTrue(app.staticTexts["mob.distance"].waitForExistence(timeout: 10))
            openClear(in: app)
            checkCard(
                "Clear this MOB mark?", confirm: "mob.confirmClear", backOut: "mob.keepClear",
                screenshot: "MOB clear mark", look: look, in: app)
            XCTAssertTrue(app.staticTexts["mob.distance"].exists)
            openClear(in: app)
            app.buttons["mob.confirmClear"].tap()
            XCTAssertTrue(element("mob.screen", in: app).waitForNonExistence(timeout: 10))
        }
    }

    func testManOverboardWaitingPressCard() {
        for look in Look.allCases {
            let app = launchDemoApp(
                extraArguments: ["-app.showManOverboardButton", "1", "-demoLocationIssue", "denied"] + look.arguments)
            pressManOverboard(in: app)
            XCTAssertTrue(app.staticTexts["mob.pending"].waitForExistence(timeout: 5))
            openClear(in: app)
            checkCard(
                "Cancel this MOB press?", confirm: "mob.confirmClear", backOut: "mob.keepClear",
                screenshot: "MOB cancel press", look: look, in: app)
            XCTAssertTrue(app.staticTexts["mob.pending"].exists)
        }
    }

    func testAnchorCards() {
        for look in Look.allCases {
            let app = launchDemoApp(extraArguments: ["-settings.distanceUnit.motorboating", "m"] + look.arguments)
            let open = app.buttons["anchor.open"]
            scrollTo(open, in: app)
            open.tap()
            let status = app.staticTexts["anchor.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            let arm = app.buttons["anchor.arm"]
            scrollTo(arm, in: app)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: arm)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)

            moveAnchorOutside(in: app)
            reach(arm, in: app)
            arm.tap()
            checkCard(
                "The boat is already outside the circle", confirm: "anchor.armAnyway",
                backOut: "anchor.keepAdjusting", screenshot: "anchor outside", look: look, in: app)
            XCTAssertEqual(label(of: status, in: app), "Alarm off")

            // Back over the boat, arming needs no confirmation; disarming asks.
            let useCurrent = app.buttons["anchor.useCurrent"]
            reach(useCurrent, in: app)
            useCurrent.tap()
            reach(arm, in: app)
            arm.tap()
            // A lazy row at the bottom: at the largest text sizes it exists only once scrolled to.
            let disarm = app.buttons["anchor.disarm"]
            reach(disarm, in: app)
            XCTAssertEqual(label(of: status, in: app), "Armed")
            openCard(with: disarm, in: app)
            checkCard(
                "Disarm the anchor alarm?", confirm: "anchor.confirmDisarm", backOut: "anchor.keepArmed",
                screenshot: "anchor disarm", look: look, in: app)
            XCTAssertEqual(label(of: status, in: app), "Armed")
            disarmConfirmed(with: disarm, status: status, in: app)

            // Arm Anyway arms outside the circle (it soon reports dragging).
            moveAnchorOutside(in: app)
            reach(arm, in: app)
            arm.tap()
            let armAnyway = app.buttons["anchor.armAnyway"]
            XCTAssertTrue(armAnyway.waitForExistence(timeout: 5))
            if !armAnyway.isHittable { scrollTo(armAnyway, in: app) }
            armAnyway.tap()
            reach(disarm, in: app)
            disarmConfirmed(with: disarm, status: status, in: app)
        }
    }

    /// Moves the anchor point well outside the 40 m circle (the map spans four radii),
    /// dragging at the side so the map itself doesn't pan.
    private func moveAnchorOutside(in app: XCUIApplication) {
        let map = element("anchor.map", in: app)
        reach(map, in: app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
    }

    /// Taps `button` until a confirmation card opens: rows above it can appear meanwhile
    /// (the drift alarm's Stop) and move it.
    private func openCard(with button: XCUIElement, in app: XCUIApplication) {
        let heading = app.staticTexts["confirmation.title"]
        for _ in 0..<3 {
            reach(button, in: app)
            button.tap()
            if heading.waitForExistence(timeout: 3) { return }
        }
        XCTFail("No confirmation card opened")
    }

    private func disarmConfirmed(with disarm: XCUIElement, status: XCUIElement, in app: XCUIApplication) {
        openCard(with: disarm, in: app)
        let confirm = app.buttons["anchor.confirmDisarm"]
        if !confirm.isHittable { scrollTo(confirm, in: app) }
        confirm.tap()
        scrollUpTo(status, in: app, column: 0.03)
        waitForLabel(status, "Alarm off", timeout: 10)
    }

    /// The status row's label, scrolling up to it: at the largest text sizes it is a lazy
    /// row that leaves the list when scrolled away.
    private func label(of status: XCUIElement, in app: XCUIApplication) -> String {
        scrollUpTo(status, in: app, column: 0.03)
        return status.label
    }

    func testTurnOffSharingCard() {
        for look in Look.allCases {
            let app = launchDemoHistory(extraArguments: ["-demoSessionSync"] + look.arguments)
            app.tabBars.buttons["Settings"].tap()
            let signIn = app.buttons["sessionSync.demoSignIn"]
            scrollTo(signIn, in: app)
            signIn.tap()
            XCTAssertTrue(element("sessionSync.signedIn", in: app).waitForExistence(timeout: 10))
            let sharing = app.buttons["sessionSync.sharing"]
            scrollTo(sharing, in: app)
            sharing.tap()
            let toggle = app.switches["sharing.enabled"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            let loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isEnabled == true AND value == '1'"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
            let confirm = app.buttons["sharing.confirmOff"]
            tapSwitch(toggle, in: app, until: { confirm.exists })
            checkCard(
                "Turn off sharing?", confirm: "sharing.confirmOff", backOut: "sharing.keepOn",
                screenshot: "turn off sharing", look: look, in: app)
            XCTAssertEqual(toggle.value as? String, "1")
        }
    }

    // MARK: Helpers

    /// Checks the open card, saves a screenshot, and backs out with `backOut`.
    private func checkCard(
        _ title: String, confirm: String, backOut: String, screenshot: String, look: Look, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let heading = app.staticTexts["confirmation.title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(heading.label, title, file: file, line: line)
        XCTAssertTrue(app.staticTexts["confirmation.message"].exists, file: file, line: line)
        // Let the sheet settle at its height.
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("\(screenshot) \(look.rawValue)")
        let window = app.windows.firstMatch.frame
        for identifier in [confirm, backOut] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, "\(identifier) is missing", file: file, line: line)
            // At accessibility sizes the card scrolls rather than clipping its buttons.
            if !button.isHittable || !window.contains(button.frame) { scrollTo(button, in: app) }
            XCTAssertTrue(button.isHittable, "\(identifier) can't be tapped", file: file, line: line)
            XCTAssertTrue(window.contains(button.frame), "\(identifier) leaves the window", file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 50, "\(identifier) is too short", file: file, line: line)
        }
        if look == .largestText { attachScreenshot("\(screenshot) \(look.rawValue) scrolled") }
        app.buttons[backOut].tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 5), "the card stayed open", file: file, line: line)
    }

    /// Scrolls to `element` in either direction: a lazy row scrolled away above no longer
    /// exists, and `scrollTo` looks for one below.
    private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        func drag(from: CGFloat, to: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to)))
        }
        // Look above first, then below.
        for _ in 0..<6 where !element.exists { drag(from: 0.3, to: 0.6) }
        for _ in 0..<12 where !element.exists { drag(from: 0.6, to: 0.3) }
        scrollTo(element, in: app, column: 0.03)
    }

    /// Drags the content up, at the window's side, until `done`.
    private func dragUntil(in app: XCUIApplication, _ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        for _ in 0..<12 where !done() {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3)))
        }
        XCTAssertTrue(done(), "never scrolled into view", file: file, line: line)
    }

    private func pressManOverboard(in app: XCUIApplication) {
        let mob = element("control.mob", in: app)
        XCTAssertTrue(mob.waitForExistence(timeout: 15))
        if !mob.isHittable { scrollTo(mob, in: app) }
        mob.press(forDuration: 1.2)
    }

    private func openClear(in app: XCUIApplication) {
        let clear = app.buttons["mob.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        // Inline at the largest text sizes, "New session" covers the bottom of the window,
        // so drag higher up than `scrollTo` does, and at the side, clear of the map.
        dragUntil(in: app) { clear.isHittable }
        clear.tap()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
