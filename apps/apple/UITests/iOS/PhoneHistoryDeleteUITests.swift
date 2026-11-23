import XCTest

/// Deleting from History's list: the swipe only offers Delete, and the recording goes only
/// once the confirmation says so. Simulator QA of #186 lost a session to two left swipes.
final class PhoneHistoryDeleteUITests: XCTestCase {
    @MainActor
    func testSwipeDeleteAsksFirst() {
        let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"])
        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        let sailing = rows.containing(.staticText, identifier: "Sailing").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        // The demo library has one sailing session. Rows load lazily, so count only those.
        let sailingRows = rows.containing(.staticText, identifier: "Sailing")
        XCTAssertEqual(sailingRows.count, 1)

        // Two long swipes, as in the report, delete nothing: they only show the button.
        sailing.swipeLeft()
        sailing.swipeLeft()
        let rowDelete = app.buttons["session.row.delete"]
        XCTAssertTrue(rowDelete.waitForExistence(timeout: 5))
        XCTAssertTrue(sailing.exists, "a swipe deleted the session")

        // The button asks first, and Cancel keeps the session.
        rowDelete.tap()
        // The confirmation's Delete, not the row's (which shares the label).
        let confirm = app.buttons
            .matching(NSPredicate(format: "label == 'Delete' AND identifier != 'session.row.delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Delete this session?"].exists)
        attachScreenshot("history delete confirmation")
        dismissConfirmation(in: app)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the confirmation stayed open")
        XCTAssertTrue(sailing.exists)

        // Confirmed, it goes.
        if !rowDelete.exists { sailing.swipeLeft() }
        XCTAssertTrue(rowDelete.waitForExistence(timeout: 5))
        rowDelete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(sailing.waitForNonExistence(timeout: 10), "the session wasn't deleted")
    }

    /// The confirmation is an action sheet or, where iOS anchors it, a popover.
    @MainActor
    private func dismissConfirmation(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        }
    }
}
