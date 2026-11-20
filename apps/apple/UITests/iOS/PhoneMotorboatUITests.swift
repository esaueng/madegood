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
            "-demoOmitMapKit",
            "-settings.fuelBurn.motorboating", "36",
        ])
        let start = app.buttons["sport.motorboating"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()

        // The demo boat runs at 2.5 m/s, above the under-way speed, so engine time and
        // the estimate grow with the session.
        let engine = element("motor.engineTime", in: app)
        XCTAssertTrue(engine.waitForExistence(timeout: 15))
        let fuel = element("motor.fuel", in: app)
        let nonzeroFuel = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in fuel.exists && (self.litres(in: fuel.label) ?? 0) >= 0.1 },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nonzeroFuel], timeout: 30), .completed)
        XCTAssertTrue(element("motor.trip", in: app).label.hasSuffix("nm"))
        XCTAssertTrue(element("motor.log", in: app).label.hasSuffix("nm"))
        scrollTo(element("motor.fuel", in: app), in: app)
        attachScreenshot("motorboat 1 live")

        // Freeze both readings before comparing them. A busy simulator can skip over
        // 0.1 L before XCTest sees it, but the estimate must still match engine time.
        app.buttons["control.pause"].tap()
        let save = app.buttons["control.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        assertFuel(fuel, matches: engine)
        save.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        let row = app.buttons.matching(identifier: "session.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let detailFuel = element("motor.fuel", in: app)
        scrollTo(detailFuel, in: app)
        assertFuel(detailFuel, matches: element("motor.engineTime", in: app))
        attachScreenshot("motorboat 2 detail")
    }

    private func litres(in label: String) -> Double? {
        guard label.hasSuffix(" L") else { return nil }
        return Double(label.dropLast(2))
    }

    private func assertFuel(_ fuel: XCUIElement, matches engine: XCUIElement) {
        let engineLabel = engine.label
        let seconds = engineLabel.split(separator: ":").compactMap { Double($0) }
            .reduce(0) { $0 * 60 + $1 }
        let fuelLabel = fuel.label
        XCTAssertGreaterThan(seconds, 0, engineLabel)
        guard let observed = litres(in: fuelLabel) else {
            XCTFail("Expected litres, got \(fuelLabel)")
            return
        }
        // Fuel is rounded to 0.1 L and engine time to whole seconds.
        XCTAssertEqual(observed, seconds * 36 / 3_600, accuracy: 0.06)
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
