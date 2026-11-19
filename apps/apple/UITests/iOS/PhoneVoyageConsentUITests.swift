import CoreLocation
import XCTest

final class PhoneVoyageConsentUITests: XCTestCase {
    @MainActor func testRecoversAndPrivatelySyncsTheCompletedLegWithConsent() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.location = nil }

        let name = "Synthetic passage \(UUID().uuidString.prefix(8))"
        let app = XCUIApplication()
        app.launchArguments = ["-demoPrivateVoyageSync"]
        app.launchEnvironment["MADEGOOD_TEST_VOYAGES"] = UUID().uuidString
        resetLocationPermission(app)
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
        allowLocationWhileUsing()
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
        let gaps = app.staticTexts["Capture Gaps"]
        XCTAssertTrue(gaps.waitForExistence(timeout: 10))

        let status = app.staticTexts["voyageSync.legStatus"]
        let sync = app.buttons["Sync Leg Privately"]
        waitForLabel(status, "On iPhone")
        XCTAssertFalse(sync.exists)

        app.tabBars.buttons["Settings"].tap()
        let signIn = app.buttons["voyageSync.demoSignIn"]
        scrollTo(signIn, in: app)
        signIn.tap()
        XCTAssertTrue(app.staticTexts["voyageSync.signedIn"].waitForExistence(timeout: 10))

        openVoyages(in: app)
        waitForLabel(status, "On iPhone")
        scrollTo(sync, in: app)
        sync.tap()
        let confirm = app.buttons["Sync Privately"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        waitForLabel(status, "On iPhone")

        sync.tap()
        confirm.tap()
        waitForLabel(status, "Synced")
        XCTAssertTrue(lastFix.exists)
        XCTAssertTrue(gaps.exists)

        app.tabBars.buttons["Settings"].tap()
        let signOut = app.buttons["voyageSync.signOut"]
        scrollTo(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        XCTAssertTrue(app.staticTexts["voyageSync.signedIn"].waitForExistence(timeout: 10))
        openVoyages(in: app)
        waitForLabel(status, "On iPhone")
        XCTAssertTrue(lastFix.exists)
        XCTAssertTrue(gaps.exists)
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
