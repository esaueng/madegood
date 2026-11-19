import XCTest

/// Settings → Your Data → Export All Recordings, on the synthetic history library.
final class PhoneExportUITests: XCTestCase {
    @MainActor
    func testExportAllRecordingsOpensTheShareSheet() {
        continueAfterFailure = false
        let app = launchDemoHistory()
        // The demo library is written on first launch; History shows it is ready.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["session.row"].firstMatch.waitForExistence(timeout: 15))

        app.tabBars.buttons["Settings"].tap()
        let export = app.buttons["settings.exportAll"]
        scrollTo(export, in: app)
        export.tap()
        // The share sheet's caption names the archive (its identifiers change between iOS versions).
        let caption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "madegood-recordings")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 30))
        attachScreenshot("Export all recordings")
    }
}
