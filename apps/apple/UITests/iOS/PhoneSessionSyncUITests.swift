import XCTest

/// Session sync against the in-process synthetic server (`-demoSessionSync`): no network.
final class PhoneSessionSyncUITests: XCTestCase {
    @MainActor
    func testSignInSyncsHistoryAndRetriesAFailedUpload() {
        continueAfterFailure = false
        let app = launchDemoHistory(extraArguments: ["-demoSessionSync"])

        // Nothing uploads before sign-in and the switch.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["session.row"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(element("session.sync", in: app).exists)

        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["sessionSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(element("sessionSync.signedIn", in: app).waitForExistence(timeout: 10))
        let enable = app.switches["sessionSync.enabled"]
        scrollTo(enable, in: app)
        XCTAssertEqual(enable.value as? String, "0")
        enable.switches.firstMatch.tap()
        XCTAssertTrue(app.switches["sessionSync.wifiOnly"].waitForExistence(timeout: 5))
        waitForLabel(element("sessionSync.syncedCount", in: app), "Synced, 2", timeout: 30)
        XCTAssertTrue(element("sessionSync.problemCount", in: app).waitForExistence(timeout: 10))
        attachScreenshot("Settings account sync")

        // History: two synced, the windsurf session refused as too large.
        app.tabBars.buttons["History"].tap()
        let badges = app.descendants(matching: .any).matching(identifier: "session.sync")
        XCTAssertTrue(badges.firstMatch.waitForExistence(timeout: 10))
        let labels = (0..<badges.count).map { badges.element(boundBy: $0).label }
        XCTAssertEqual(labels.filter { $0 == "Synced" }.count, 2, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == "Too large to upload" }.count, 1, "\(labels)")
        attachScreenshot("History sync status")

        let failedRow = app.buttons.matching(identifier: "session.row")
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "Windsurf")).firstMatch
        XCTAssertTrue(failedRow.exists)
        failedRow.tap()
        let status = element("sessionSync.status", in: app)
        scrollTo(status, in: app)
        XCTAssertEqual(status.label, "Too large to upload")
        attachScreenshot("Session detail failed upload")

        let retry = app.buttons["sessionSync.retry"]
        scrollTo(retry, in: app)
        retry.tap()
        waitForLabel(status, "Synced", timeout: 30)
        XCTAssertFalse(retry.exists)
        attachScreenshot("Session detail synced")
    }
}
