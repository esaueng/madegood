import XCTest

/// History → Statistics on the synthetic history: three charts, the period picker and the
/// sport filter.
final class PhoneStatisticsUITests: XCTestCase {
    @MainActor
    func testStatisticsByPeriodAndSport() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["session.row"].firstMatch.waitForExistence(timeout: 15))
        // Every demo session is analyzed before the totals count all three.
        waitForLabelPrefix(element("history.totals", in: app), "3\u{00A0}sessions\u{00A0}· ")
        app.buttons["history.statistics"].tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 10))

        for title in ["Distance", "Moving time"] {
            XCTAssertTrue(element("statistics.chart.\(title)", in: app).waitForExistence(timeout: 10), title)
        }
        attachScreenshot("statistics by month")

        // The demo sessions are 2, 9 and 33 days old: all three fall in the last 12 weeks.
        app.buttons["Week"].tap()
        let distanceChart = element("statistics.chart.Distance", in: app)
        XCTAssertTrue(distanceChart.exists)
        app.buttons["Year"].tap()
        attachScreenshot("statistics by year")

        // One sport: only the windsurf session is left, so its distance is the year's best.
        app.buttons["statistics.sportFilter"].tap()
        app.buttons["Windsurfing"].tap()
        let best = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "best 6.11")).firstMatch
        XCTAssertTrue(best.waitForExistence(timeout: 5), "the windsurf session's 6.11 nm is the best")
        attachScreenshot("statistics windsurfing")
    }

    /// The screen in dark mode, for a look at the metric colors on the dark cards.
    @MainActor
    func testStatisticsDark() {
        let app = launchDemoHistory(extraArguments: ["-app.appearance", "dark"])
        app.tabBars.buttons["History"].tap()
        waitForLabelPrefix(element("history.totals", in: app), "3\u{00A0}sessions\u{00A0}· ")
        app.buttons["history.statistics"].tap()
        XCTAssertTrue(element("statistics.chart.Distance", in: app).waitForExistence(timeout: 10))
        let total = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "total 24.2")).firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 5), "all three sessions' distance")
        attachScreenshot("statistics dark")
    }
}
