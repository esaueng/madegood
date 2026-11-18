import XCTest

final class PhoneWatchMirrorUITests: XCTestCase {
    func testAWatchMirrorArrivingDuringStandaloneRecordingWaitsForLocalSave() {
        continueAfterFailure = false
        let app = launchDemoApp(extraArguments: ["-demoWatchMirror"])
        let kayak = app.buttons["sport.kayak"]
        scrollTo(kayak, in: app)
        kayak.tap()

        let watchStatus = element("status.watchWorkout", in: app)
        XCTAssertTrue(app.buttons["control.pause"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Kayak"].exists)
        XCTAssertFalse(watchStatus.exists)

        endSession(app)
        XCTAssertTrue(watchStatus.waitForExistence(timeout: 15))
        XCTAssertTrue(watchStatus.label.contains("On Watch"))
        XCTAssertTrue(app.navigationBars["Canoe"].exists)
        XCTAssertFalse(app.buttons["control.pause"].exists)
        XCTAssertFalse(app.buttons["control.save"].exists)
    }
}
