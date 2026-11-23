import SwiftUI
import WaterKit
import XCTest

@testable import MadeGood

/// Simulator QA of #186: white text on the start warnings measured 2.6–2.8:1. Small text
/// needs 4.5:1 (WCAG 2.1 AA).
final class StartLineBannerContrastTests: XCTestCase {
    private func luminance(_ color: Color) -> Double {
        // Resolved components are linear, as relative luminance wants them.
        let resolved = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testWarningTextMeetsSmallTextContrast() {
        let checks: [StartCheck] = [.over(distance: 3), .possiblyOver(distance: 2), .unknown]
        for check in checks {
            let ratio = contrast(StartLineBanner.ink, OCSBanner.fill(for: check))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(check): \(ratio):1")
        }
        XCTAssertGreaterThanOrEqual(contrast(StartLineBanner.ink, StartLineBanner.gray), 4.5)
    }

    func testTheOldWhiteTextFailed() {
        XCTAssertLessThan(contrast(.white, Theme.coral), 4.5)
    }
}
