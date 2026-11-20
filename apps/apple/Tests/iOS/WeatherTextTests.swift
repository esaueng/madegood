import WaterKit
import XCTest

@testable import MadeGood

final class WeatherTextTests: XCTestCase {
    func testWeatherTextUsesWholeNumbersAndCompass() {
        let weather = WeatherNow(time: 0, temperature: 20, code: 1, windSpeed: 6.5, windGust: 9.5, windFrom: 225)
        let text = WeatherText(weather, speedUnit: .knots)
        XCTAssertEqual(text.headline, "Good sailing breeze")
        XCTAssertEqual(text.wind, "13 kn SW · gusts 18")
        XCTAssertEqual(WeatherText.compass(350), "N")
        XCTAssertEqual(WeatherText.compass(-90), "W")
        XCTAssertEqual(WeatherText.when(1_000, now: 0), "soon")
    }

    /// Regression: a cached answer's warning is worded against the clock, not the fetch.
    func testWarningTimeFollowsTheClock() {
        let thunderAt = 1_800_003_600.0
        let weather = WeatherNow(
            time: 1_800_000_000, temperature: 20, code: 1, windSpeed: 5, windFrom: 225,
            hours: [.init(time: thunderAt, code: 95)])
        let fresh = WeatherText(weather, speedUnit: .knots, now: Date(timeIntervalSince1970: weather.time))
        XCTAssertTrue(fresh.warning?.hasPrefix("Thunder likely by ") == true, fresh.warning ?? "nil")
        let later = WeatherText(weather, speedUnit: .knots, now: Date(timeIntervalSince1970: thunderAt - 600))
        XCTAssertEqual(later.warning, "Thunder likely soon")
    }
}
