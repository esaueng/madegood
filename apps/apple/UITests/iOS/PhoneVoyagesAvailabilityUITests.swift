import XCTest

final class PhoneVoyagesAvailabilityUITests: XCTestCase {
    @MainActor func testVoyagesTabFollowsBuildConfiguration() {
        let tabs = launchDemoApp().tabBars
        XCTAssertTrue(tabs.buttons["Record"].waitForExistence(timeout: 10))

        #if DEBUG
            XCTAssertTrue(tabs.buttons["Voyages"].exists)
        #else
            XCTAssertFalse(tabs.buttons["Voyages"].exists)
        #endif
    }
}
