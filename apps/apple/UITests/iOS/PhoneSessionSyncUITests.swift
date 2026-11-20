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
        // The account's Visibility of new sessions is shown before the switch is turned on.
        waitForLabel(element("sessionSync.visibility", in: app), "Visibility of new sessions, Private")
        enable.switches.firstMatch.tap()
        XCTAssertTrue(app.switches["sessionSync.wifiOnly"].waitForExistence(timeout: 5))

        // The synthetic sessions predate the sign-in: they wait for an explicit choice.
        let earlier = app.buttons["sessionSync.uploadEarlier"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 15))
        XCTAssertEqual(earlier.label, "Upload 3 Earlier Sessions")
        waitForLabel(element("sessionSync.syncedCount", in: app), "Synced, 0")
        scrollTo(earlier, in: app)
        earlier.tap()
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

        // Signing out turns sync off; signing in again needs the switch again.
        app.tabBars.buttons["Settings"].tap()
        let signOut = app.buttons["sessionSync.signOut"]
        scrollTo(signOut, in: app)
        signOut.tap()
        scrollTo(signIn, in: app)
        signIn.tap()
        scrollTo(enable, in: app)
        XCTAssertEqual(enable.value as? String, "0")
    }

    /// A Public account default is shown beside Sync sessions with a warning that new
    /// uploads are shared automatically (review of #133, finding 2).
    @MainActor
    func testSyncSwitchShowsAPublicAccountDefault() {
        continueAfterFailure = false
        let app = launchDemoHistory(extraArguments: ["-demoSessionSync", "-demoSessionVisibility", "public"])
        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["sessionSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(element("sessionSync.signedIn", in: app).waitForExistence(timeout: 10))
        let visibility = element("sessionSync.visibility", in: app)
        scrollTo(visibility, in: app)
        waitForLabel(visibility, "Visibility of new sessions, Public")
        let notice = element("sessionSync.visibilityNotice", in: app)
        XCTAssertTrue(notice.label.hasPrefix("New uploads will be public automatically"), notice.label)
        XCTAssertTrue(notice.label.contains("Settings on madegood.app"), notice.label)
        attachScreenshot("Settings public visibility")
    }

    /// Settings → Delete Account: confirmation first, then signed out with the recordings kept.
    @MainActor
    func testDeleteAccountConfirmsThenSignsOutAndKeepsRecordings() {
        continueAfterFailure = false
        let app = launchDemoHistory(extraArguments: ["-demoSessionSync"])
        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["sessionSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(element("sessionSync.signedIn", in: app).waitForExistence(timeout: 10))

        let delete = app.buttons["sessionSync.deleteAccount"]
        scrollTo(delete, in: app)
        delete.tap()
        let alert = app.alerts["Delete your MadeGood account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "stay on your devices")).firstMatch
                .exists)
        attachScreenshot("Delete account confirmation")

        // Cancel keeps everything.
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(element("sessionSync.signedIn", in: app).exists)

        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete Account"].firstMatch.tap()
        let message = element("sessionSync.message", in: app)
        waitForLabel(message, "Your account was deleted. Recordings stay on this iPhone.", timeout: 15)
        XCTAssertTrue(app.buttons["sessionSync.demoSignIn"].exists)
        XCTAssertFalse(element("sessionSync.signedIn", in: app).exists)
        attachScreenshot("Account deleted")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["session.row"].firstMatch.waitForExistence(timeout: 10))
    }
}
