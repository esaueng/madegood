import XCTest

/// The motorboat profile on iPhone: the trip log and fuel estimate on the live page and in
/// session detail, and the fuel settings.
final class PhoneMotorboatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testMotorboatLiveLogFuelAndDetail() {
        let app = launchDemoApp(extraArguments: [
            "-app.appearance", "light",
            "-settings.fuelBurn.motorboating", "36",
        ])
        let start = app.buttons["sport.motorboating"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()

        // The demo boat runs at 2.5 m/s, above the under-way speed, so engine time and
        // the estimate grow with the session.
        let engine = element("motor.engineTime", in: app)
        XCTAssertTrue(engine.waitForExistence(timeout: 15))
        // The live map's position asks for location once on a fresh simulator.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let fuel = element("motor.fuel", in: app)
        waitForLabel(fuel, "0.1 L", timeout: 30)  // 36 L/h ≈ 0.1 L after 10 s
        XCTAssertTrue(element("motor.trip", in: app).label.hasSuffix("nm"))
        XCTAssertTrue(element("motor.log", in: app).label.hasSuffix("nm"))
        scrollTo(element("motor.fuel", in: app), in: app)
        attachScreenshot("motorboat 1 live")

        endSession(app)
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        let row = app.buttons.matching(identifier: "session.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let detailFuel = element("motor.fuel", in: app)
        scrollTo(detailFuel, in: app)
        XCTAssertTrue(detailFuel.label.hasSuffix(" L"), detailFuel.label)
        XCTAssertNotEqual(element("motor.engineTime", in: app).label, "0:00")
        attachScreenshot("motorboat 2 detail")
    }

    func testFuelSettingsAreEditable() {
        let app = launchDemoApp(extraArguments: ["-app.appearance", "dark"])
        let gear = app.buttons["sportSettings.open.motorboating"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        let burn = app.textFields["sportSettings.fuelBurn"]
        scrollTo(burn, in: app)
        burn.tap()
        burn.typeText("24")
        app.textFields["sportSettings.fuelIdleBurn"].tap()
        XCTAssertEqual(burn.value as? String, "24")
        attachScreenshot("motorboat 3 fuel settings")
    }
}
