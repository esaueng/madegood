import XCTest

/// Settings → About links to the privacy policy.
final class PhonePrivacyUITests: XCTestCase {
    @MainActor
    func testSettingsLinksToThePrivacyPolicy() {
        continueAfterFailure = false
        let app = launchDemoApp()
        app.tabBars.buttons["Settings"].tap()
        let privacy = element("settings.privacyPolicy", in: app)
        scrollTo(privacy, in: app)
        XCTAssertTrue(privacy.isHittable)
        XCTAssertTrue(privacy.label.contains("Privacy Policy"))
        attachScreenshot("Settings privacy policy link")
    }
}
