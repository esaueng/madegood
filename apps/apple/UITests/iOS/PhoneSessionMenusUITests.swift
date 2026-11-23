import XCTest

/// The session detail's toolbar menus: share (GPX and raw recording, with the privacy
/// note) and ⋯ (trim and delete).
final class PhoneSessionMenusUITests: XCTestCase {
    @MainActor
    func testShareAndMoreMenus() {
        let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"])
        app.tabBars.buttons["History"].tap()
        let sailing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()

        // Share: both exports, under the note on what a file holds.
        // By label: items in a menu section don't keep their accessibility identifiers.
        openSessionMenu("session.share", in: app)
        let gpx = app.buttons["Export GPX"]
        XCTAssertTrue(gpx.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share Raw Recording"].exists)
        let note = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Exports contain precise locations and times"))
            .firstMatch
        XCTAssertTrue(note.exists)
        attachScreenshot("share menu")
        gpx.tap()
        // The share sheet's caption names the file, "sailing-<start>", without its extension
        // (the sheet's identifiers change between iOS versions).
        let caption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "sailing-")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 20))
        app.swipeDown(velocity: .fast)

        // ⋯: trim, then delete behind a confirmation.
        openSessionMenu("session.more", in: app)
        XCTAssertTrue(app.buttons["session.trim"].waitForExistence(timeout: 5))
        let delete = app.buttons["session.delete"]
        XCTAssertTrue(delete.exists)
        attachScreenshot("more menu")
        delete.tap()
        let confirm = app.buttons["session.confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["confirmation.title"].label, "Delete this session?")
        XCTAssertTrue(element("session.deleteSummary", in: app).exists)
        // Keep backs out: the card closes and the detail is still open.
        app.buttons["session.keep"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "the confirmation stayed open")
        XCTAssertTrue(app.buttons["session.panel.handle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Sailing"].exists)

        // Confirming deletes it and returns to History.
        openSessionMenu("session.more", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        XCTAssertTrue(sailing.waitForNonExistence(timeout: 10))
    }
}
