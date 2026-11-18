import XCTest

/// The Appearance picker in Settings: the choice applies straight away and survives a
/// relaunch. The screen's brightness is sampled to check the style really changed.
final class PhoneAppearanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppearanceChoiceAppliesAndPersists() {
        // Start from the style the simulator isn't using, so each step is a real change.
        var app = launchDemoApp(extraArguments: [])
        var picker = openAppearance(app)
        let systemIsDark = isDark(app)

        let opposite = systemIsDark ? "Light" : "Dark"
        picker.buttons[opposite].tap()
        XCTAssertTrue(picker.buttons[opposite].isSelected)
        expectDark(!systemIsDark, app)
        attachScreenshot("settings \(opposite.lowercased())")

        app.terminate()
        app = launchDemoApp(resetSettings: false)
        picker = openAppearance(app)
        XCTAssertTrue(picker.buttons[opposite].isSelected)
        expectDark(!systemIsDark, app)

        picker.buttons["System"].tap()
        XCTAssertTrue(picker.buttons["System"].isSelected)
        expectDark(systemIsDark, app)
        attachScreenshot("settings system")
    }

    private func openAppearance(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()
        let picker = app.segmentedControls["settings.appearance"]
        for _ in 0..<4 where !picker.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(picker.exists)
        return picker
    }

    private func expectDark(_ dark: Bool, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while isDark(app) != dark, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(isDark(app), dark, "expected a \(dark ? "dark" : "light") screen", file: file, line: line)
    }

    /// Whether the screen background, just below the status bar, is dark.
    private func isDark(_ app: XCUIApplication) -> Bool {
        guard let image = app.screenshot().image.cgImage else { return false }
        let x = 8
        let y = image.height / 12
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let brightness = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
        return brightness < 128
    }
}
