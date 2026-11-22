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
        scrollFullyIntoView(enable, in: app)
        XCTAssertEqual(enable.value as? String, "0")
        // Under the switch: where new uploads take their visibility from (#133).
        let notice = element("sessionSync.visibilityNotice", in: app)
        XCTAssertTrue(notice.exists)
        XCTAssertEqual(
            notice.label,
            "New uploads use your account’s Visibility of new sessions, which you set in Settings on madegood.app. If it’s Unlisted or Public, new sessions are shared that way automatically. Turn sharing off under Sharing to keep everything private."
        )
        setSwitch(enable, on: true, in: app)
        // Turning sync on reveals the row below it, which can start under the tab bar.
        let wifiOnly = app.switches["sessionSync.wifiOnly"]
        // It may not exist until scrolled to (a lazy row); scrollFullyIntoView fails if it never does.
        _ = wifiOnly.waitForExistence(timeout: 5)
        scrollFullyIntoView(wifiOnly, in: app)

        // The synthetic sessions predate the sign-in: they wait for an explicit choice.
        let earlier = app.buttons["sessionSync.uploadEarlier"]
        // The row appears once the scan finishes and may sit below the fold of the lazy list.
        let deadline = Date.now.addingTimeInterval(15)
        while !earlier.exists, Date.now < deadline {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(
                forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
            _ = earlier.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(earlier.exists)
        XCTAssertEqual(earlier.label, "Upload 3 Earlier Sessions")
        waitForLabel(element("sessionSync.syncedCount", in: app), "Synced, 0")
        scrollTo(earlier, in: app)
        earlier.tap()
        waitForLabel(element("sessionSync.syncedCount", in: app), "Synced, 2", timeout: 30)
        XCTAssertTrue(element("sessionSync.problemCount", in: app).waitForExistence(timeout: 10))
        attachScreenshot("Settings account sync")

        // History: two synced, the windsurf session refused as too large.
        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        // The list loads rows as they scroll in, so check each session's badge in turn.
        func badge(_ sport: String) -> String {
            let row = rows.containing(.staticText, identifier: sport).firstMatch
            scrollTo(row, in: app)
            let badge = row.descendants(matching: .any).matching(identifier: "session.sync").firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 10), sport)
            return badge.label
        }
        XCTAssertEqual(badge("Sailing"), "Synced")
        XCTAssertEqual(badge("Kayak"), "Synced")
        XCTAssertEqual(badge("Windsurfing"), "Too large to upload")
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

    /// Settings → Sharing: the shared sessions with Make Private, then the switch turns all
    /// sharing off after a confirmation.
    @MainActor
    func testSharingListsSharedSessionsAndTurnsSharingOff() {
        continueAfterFailure = false
        let app = launchDemoHistory(extraArguments: ["-demoSessionSync"])
        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["sessionSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(element("sessionSync.signedIn", in: app).waitForExistence(timeout: 10))

        let sharing = app.buttons["sessionSync.sharing"]
        scrollTo(sharing, in: app)
        sharing.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "sharing.session")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
        let toggle = app.switches["sharing.enabled"]
        XCTAssertEqual(toggle.value as? String, "1")
        attachScreenshot("Sharing settings")

        app.buttons.matching(identifier: "sharing.makePrivate").firstMatch.tap()
        let deadline = Date.now.addingTimeInterval(10)
        while rows.count != 1, Date.now < deadline { RunLoop.current.run(until: .now.addingTimeInterval(0.2)) }
        XCTAssertEqual(rows.count, 1)

        // Turning sharing off asks first; the switch stays on until confirmed.
        let confirm = app.buttons.matching(identifier: "sharing.confirmOff").firstMatch
        tapSwitch(toggle, in: app, until: { confirm.exists })
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element("sharing.none", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        attachScreenshot("Sharing turned off")
    }
}
