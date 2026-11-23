import XCTest

/// A deleted session waits in History → Recently Deleted, where it can be recovered or
/// deleted for good.
final class PhoneRecentlyDeletedUITests: XCTestCase {
    @MainActor
    func testADeletedSessionCanBeRecoveredThenDeletedForGood() {
        let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"])
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(sailingCard(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["history.recentlyDeleted"].exists, "nothing deleted yet")

        deleteSailing(in: app)
        let deleted = recentlyDeletedLink(in: app)
        XCTAssertTrue(deleted.exists)
        deleted.tap()
        let row = app.buttons.matching(identifier: "deleted.row").containing(.staticText, identifier: "Sailing")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("30 days"), "row label: \(row.label)")
        attachScreenshot("recently deleted")

        // Recover: back in History, and Recently Deleted is empty.
        row.tap()
        let recover = app.buttons["Recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 5))
        recover.tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Sessions"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sailingCard(in: app).waitForExistence(timeout: 10))

        // Delete it again, then for good.
        deleteSailing(in: app)
        recentlyDeletedLink(in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let permanently = app.buttons["Delete Permanently"]
        XCTAssertTrue(permanently.waitForExistence(timeout: 5))
        permanently.tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Sessions"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["history.statistics"].waitForExistence(timeout: 5))
        XCTAssertFalse(sailingCard(in: app).exists)
        XCTAssertFalse(app.buttons["history.recentlyDeleted"].exists)
    }

    private func sailingCard(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "session.row").containing(.staticText, identifier: "Sailing").firstMatch
    }

    /// Deletes the sailing session from its detail's ⋯ menu, back to History.
    @MainActor
    private func deleteSailing(in app: XCUIApplication) {
        let card = sailingCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["session.panel.handle"].waitForExistence(timeout: 20))
        openSessionMenu("session.more", in: app)
        app.buttons["session.delete"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "It moves to Recently Deleted"))
                .firstMatch.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["history.statistics"].waitForExistence(timeout: 10))
    }

    /// History's last row, scrolled to.
    @MainActor
    private func recentlyDeletedLink(in app: XCUIApplication) -> XCUIElement {
        let link = app.buttons["history.recentlyDeleted"]
        for _ in 0..<8 where !link.isHittable {
            app.swipeUp()
        }
        return link
    }
}
