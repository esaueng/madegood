import XCTest

final class PhoneOffWaterTrimUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPreviewAcceptSaveAndRestoreAnOffWaterCutOnAnExistingTrim() {
        let app = launchBoundaryDemo(["-demoOffWaterV1Trim"])
        openRecording(in: app)
        let trim = app.buttons["session.trim"]
        let duration = app.staticTexts["stat.Total time"]
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "4:30")
        openSessionMenu("session.more", in: app)
        trim.tap()

        let propose = app.buttons["trim.suggestion.preview"]
        XCTAssertTrue(propose.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["trim.suggestion.range"].label, "Recording 1:44 to 2:51")
        XCTAssertEqual(app.staticTexts["trim.suggestion.replayRange"].label, "Replay 1:34 to 2:41")
        XCTAssertTrue(app.staticTexts["trim.suggestion.reason"].label.contains("water fixes on both sides"))
        propose.tap()
        // The cut's preview opens below the suggestion; the list under the map is short.
        let accept = app.buttons["trim.suggestion.accept"]
        scrollTo(accept, in: app)
        let before = element("trim.preview.Before cut", in: app)
        let after = element("trim.preview.After cut", in: app)
        XCTAssertTrue(before.label.contains("4:30"))
        XCTAssertTrue(after.label.contains("3:23"))
        XCTAssertFalse(app.sliders["trim.cut.0.start"].exists)
        let save = app.buttons["trim.save"]
        XCTAssertFalse(save.isEnabled)
        let close = app.buttons["trim.suggestion.close"]
        scrollTo(close, in: app)
        close.tap()
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.sliders["trim.cut.0.start"].exists)

        scrollTo(propose, in: app)
        propose.tap()
        scrollTo(accept, in: app)
        accept.tap()
        XCTAssertTrue(app.sliders["trim.cut.0.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["Trim Session"].waitForNonExistence(timeout: 5))

        app.terminate()
        launchFresh(app)
        openRecording(in: app)
        let cut = element("replay.removedInterval", in: app)
        XCTAssertTrue(cut.waitForExistence(timeout: 5))
        XCTAssertEqual(cut.label, "1:34 to 2:41")
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "3:23")

        let split = app.buttons["moments.split.1"]
        scrollTo(split, in: app)
        XCTAssertTrue(split.label.contains("3:23 moving"))
        split.tap()
        let highlight = app.staticTexts["replay.range"]
        waitForLabel(highlight, "Split 1 (partial) · 0:00 to 4:30")
        XCTAssertEqual(highlight.value as? String, "2 highlighted route segments")
        XCTAssertEqual(app.staticTexts["stat.Elapsed"].label, "0:00")
        let cursor = element("chart.speed", in: app).value as? String
        XCTAssertTrue(cursor?.hasPrefix("0:00 elapsed, GPS speed ") == true)
        XCTAssertFalse(cursor?.contains("unavailable") == true)

        openSessionMenu("session.more", in: app)
        trim.tap()
        let undo = app.buttons["trim.cut.0.undo"]
        scrollTo(undo, in: app)
        undo.tap()
        waitUntilEnabled(save)
        save.tap()
        reopenRecording(in: app)
        XCTAssertFalse(cut.exists)
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "4:30")

        openSessionMenu("session.more", in: app)
        trim.tap()
        let restore = app.buttons["trim.restore"]
        scrollTo(restore, in: app)
        restore.tap()
        reopenRecording(in: app)
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "4:40")
    }

    @MainActor
    func testUnsupportedPackLeavesTheManualEditorAvailable() {
        let app = launchBoundaryDemo(["-demoUnsupportedBoundaryPack"])
        openRecording(in: app)
        let trim = app.buttons["session.trim"]
        openSessionMenu("session.more", in: app)
        trim.tap()
        XCTAssertTrue(app.sliders["trim.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["trim.suggestion.preview"].waitForExistence(timeout: 2))
        let addCut = app.buttons["trim.addCut"]
        scrollTo(addCut, in: app)
        addCut.tap()
        XCTAssertTrue(app.sliders["trim.cut.0.start"].waitForExistence(timeout: 5))
        let save = app.buttons["trim.save"]
        waitUntilEnabled(save)
        save.tap()
        reopenRecording(in: app)
        XCTAssertTrue(element("replay.removedInterval", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchBoundaryDemo(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoOffWater"] + arguments
        app.launchEnvironment["MADEGOOD_OFF_WATER_TEST_RUN"] = UUID().uuidString
        launchFresh(app)
        return app
    }

    @MainActor
    private func openRecording(in app: XCUIApplication) {
        let row = app.buttons.matching(identifier: "session.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Kayak"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reopenRecording(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Trim Session"].waitForNonExistence(timeout: 5))
        app.navigationBars.buttons["History"].tap()
        openRecording(in: app)
    }

    @MainActor
    private func waitUntilEnabled(_ button: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }
}
