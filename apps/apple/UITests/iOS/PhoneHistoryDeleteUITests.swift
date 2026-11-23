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

        // The button asks first, naming the session, and Keep keeps it.
        rowDelete.tap()
        let confirm = app.buttons["session.confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // Since #191 a deleted session waits in Recently Deleted; the card says so.
        XCTAssertEqual(app.staticTexts["confirmation.title"].label, "Delete this session?")
        XCTAssertTrue(
            app.staticTexts["confirmation.message"].label.hasPrefix("It moves to Recently Deleted"),
            "the card should say where the session goes")
        XCTAssertTrue(
            element("session.deleteSummary", in: app).label.contains("Sailing"), "the card should name the session")
        attachScreenshot("history delete confirmation")
        app.buttons["session.keep"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "the confirmation stayed open")
        XCTAssertTrue(sailing.exists)

        // Confirmed, it goes.
        if !rowDelete.exists { sailing.swipeLeft() }
        XCTAssertTrue(rowDelete.waitForExistence(timeout: 5))
        rowDelete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(sailing.waitForNonExistence(timeout: 10), "the session wasn't deleted")
    }
}
