import XCTest

@testable import MadeGood

final class FormattingTests: XCTestCase {
    /// Regression (QA-02): History totals split "24.2" / "km" across lines at the largest
    /// text size. Only the space after each separator may break.
    func testMetricLineBreaksOnlyBetweenMetrics() {
        let line = Formatting.metricLine(["3 sessions", "24.2 km", Formatting.duration(6_360)])
        XCTAssertEqual(line, "3\u{00A0}sessions\u{00A0}· 24.2\u{00A0}km\u{00A0}· 1\u{00A0}h\u{00A0}46\u{00A0}min")
        XCTAssertEqual(line.replacingOccurrences(of: "\u{00A0}", with: " "), "3 sessions · 24.2 km · 1 h 46 min")
        XCTAssertEqual(Formatting.metricLine(["1 session"]), "1\u{00A0}session")
        XCTAssertEqual(Formatting.metricLine([]), "")
    }
}
