import XCTest

final class PhonePrivateVoyageSyncUITests: XCTestCase {
    @MainActor
    func testSyntheticAccountCanSignOutAndBackIn() {
        continueAfterFailure = false
        let app = launchDemoApp(extraArguments: ["-demoPrivateVoyageSync"])
        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["voyageSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(app.staticTexts["voyageSync.signedIn"].waitForExistence(timeout: 10))

        let signOut = app.buttons["voyageSync.signOut"]
        scrollTo(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        XCTAssertTrue(app.staticTexts["voyageSync.signedIn"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("voyageSync.synced", in: app).exists)
    }
}
