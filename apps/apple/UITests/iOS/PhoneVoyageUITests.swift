import CoreLocation
import XCTest

final class PhoneVoyageUITests: XCTestCase {
    @MainActor func testRelaunchRestartsTheActiveLegAndShowsTheGap() throws {
        continueAfterFailure = false
        // A teardown block, not `defer`: it also runs after a failed assertion stops the
        // test, so a recording leg never keeps receiving fixes into the next test.
        addTeardownBlock { @MainActor in XCUIDevice.shared.location = nil }

        let name = "Synthetic passage \(UUID().uuidString.prefix(8))"
        let app = XCUIApplication()
        app.launchEnvironment["MADEGOOD_TEST_VOYAGES"] = UUID().uuidString
        resetLocationPermission(app)
        launchFresh(app)
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
        allowLocationWhileUsing()
        simulatePosition(longitude: -30)
        let lastFix = element("voyage.lastSavedPosition", in: app)
        XCTAssertTrue(lastFix.waitForExistence(timeout: 20))
        let savedCount = element("voyage.activeFixCount", in: app)
        let countBeforeRestart = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(countBeforeRestart, 0)

        // Stop the leg's location updates and sessions (the leg stays active) and the
        // simulated fixes before terminating: otherwise Core Location relaunches the app in
        // the background, without this test's environment. The leg must come back from the
        // explicit launch.
        let stopUpdates = app.buttons["voyage.test.stopUpdates"]
        scrollTo(stopUpdates, in: app)
        stopUpdates.tap()
        XCTAssertTrue(app.buttons["Resume Leg"].waitForExistence(timeout: 10))
        XCUIDevice.shared.location = nil
        terminateAndSettle(app)
        launchFresh(app)
        openVoyages(in: app)
        let activeLeg = element("voyage.activeLeg", in: app)
        XCTAssertTrue(activeLeg.waitForExistence(timeout: 10))
        XCTAssertEqual(activeLeg.value as? String, "Recording")
        activeLeg.tap()
        let resume = app.buttons["Resume Leg"]
        XCTAssertTrue(lastFix.exists)
        let recoveredCount = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThanOrEqual(recoveredCount, countBeforeRestart)
        simulatePosition(longitude: -29.999)
        XCTAssertTrue(app.staticTexts["Latest Capture Gap"].waitForExistence(timeout: 20))
        let countAdvanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", String(countBeforeRestart)), object: savedCount)
        XCTAssertEqual(XCTWaiter().wait(for: [countAdvanced], timeout: 15), .completed)
        let resumedCount = try XCTUnwrap((savedCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(resumedCount, countBeforeRestart)
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
