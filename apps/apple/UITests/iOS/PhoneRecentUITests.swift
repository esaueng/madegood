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

        // The row scrolls sideways to the later sessions: the windsurf session is third.
        let windsurfing = cards.containing(.staticText, identifier: "Windsurfing").firstMatch
        let window = app.windows.firstMatch
        func onScreen() -> Bool {
            windsurfing.exists && windsurfing.isHittable && windsurfing.frame.maxX <= window.frame.maxX
        }
        // Drag across the row itself, at the cards' height, from right to left.
        let rowY = sailing.frame.midY
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let right = origin.withOffset(CGVector(dx: window.frame.width * 0.85, dy: rowY))
        let left = origin.withOffset(CGVector(dx: window.frame.width * 0.15, dy: rowY))
        for _ in 0..<3 where !onScreen() {
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(windsurfing.isHittable)
        XCTAssertLessThanOrEqual(windsurfing.frame.maxX, app.windows.firstMatch.frame.maxX)
        // Back to the first card.
        for _ in 0..<3 where !sailing.isHittable {
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.2)
        }

        sailing.tap()
        XCTAssertTrue(element("replay.map", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Sailing"].exists)
    }
}
