import CoreLocation
import XCTest

final class PhoneVoyageUITests: XCTestCase {
    @MainActor func testRecoversTheActiveLegAndShowsTheGapAfterResume() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.location = nil }

        let name = "Synthetic passage \(UUID().uuidString.prefix(8))"
        let app = XCUIApplication()
        app.launch()
        openVoyages(in: app)
        app.buttons["New Voyage"].tap()
        let form = app.alerts["New Voyage"]
        let field = form.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        form.buttons["Create"].tap()

        let start = app.buttons["Start Leg"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLocation = springboard.buttons["Allow While Using App"]
        if allowLocation.waitForExistence(timeout: 5) { allowLocation.tap() }
        simulatePosition(longitude: -30)
        let lastFix = element("voyage.lastSavedPosition", in: app)
        XCTAssertTrue(lastFix.waitForExistence(timeout: 20))
        let savedCount = element("voyage.activeFixCount", in: app)
        let countBeforeRestart = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(countBeforeRestart, 0)

        app.terminate()
        app.launch()
        openVoyages(in: app)
        let activeLeg = element("voyage.activeLeg", in: app)
        XCTAssertTrue(activeLeg.waitForExistence(timeout: 10))
        XCTAssertEqual(activeLeg.value as? String, "Capture interrupted")
        activeLeg.tap()
        let resume = app.buttons["Resume Leg"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(lastFix.exists)
        let recoveredCount = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThanOrEqual(recoveredCount, countBeforeRestart)
        resume.tap()
        simulatePosition(longitude: -29.999)
        XCTAssertTrue(app.staticTexts["Latest Capture Gap"].waitForExistence(timeout: 20))
        let resumedCount = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(resumedCount, recoveredCount)
        XCTAssertFalse(resume.exists)

        app.buttons["End Leg"].tap()
        let savedLeg = app.buttons["voyage.savedLeg"]
        XCTAssertTrue(savedLeg.waitForExistence(timeout: 10))
        savedLeg.tap()
        XCTAssertTrue(app.staticTexts["Capture Gaps"].waitForExistence(timeout: 10))
    }

    @MainActor private func openVoyages(in app: XCUIApplication) {
        let tab = app.tabBars.buttons["Voyages"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
    }

    @MainActor private func simulatePosition(longitude: Double) {
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3,
                timestamp: .now))
    }
}
