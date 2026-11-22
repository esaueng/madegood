import XCTest

/// The start screen's Recent row: compact cards that scroll sideways and open the session.
final class PhoneRecentUITests: XCTestCase {
    @MainActor
    func testRecentCardsOpenTheirSession() {
        let app = launchDemoHistory()
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 15))
        let cards = app.buttons.matching(identifier: "recent.session")
        let sailing = cards.containing(.staticText, identifier: "Sailing").firstMatch
        scrollTo(sailing, in: app)
        // Distance and moving time arrive with the history summaries.
        XCTAssertTrue(sailing.staticTexts["48:00"].waitForExistence(timeout: 15))
        XCTAssertTrue(cards.containing(.staticText, identifier: "Kayak").firstMatch.exists)
        attachScreenshot("recent cards")

        sailing.tap()
        XCTAssertTrue(element("replay.map", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Sailing"].exists)
    }
}
