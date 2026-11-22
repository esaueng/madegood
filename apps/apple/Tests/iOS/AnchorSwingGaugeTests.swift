import XCTest

@testable import MadeGood

/// Review regressions: the swing gauge showed a calm reading the alarm disagreed with.
final class AnchorSwingGaugeTests: XCTestCase {
    private func zone(_ distance: Double?, accuracy: Double?, usable: Bool = true, dragging: Bool = false)
        -> AnchorSwingGauge.Zone
    {
        AnchorSwingGauge.zone(
            distance: distance, accuracy: accuracy, isUsable: usable, isDragging: dragging, radius: 40)
    }

    /// Drift confirmed, then a fresh but poor fix at 20 m (±50 m): the gauge must not show
    /// the boat comfortably inside while the alarm says the anchor is dragging.
    func testDraggingWinsOverAnyFix() {
        XCTAssertEqual(zone(20, accuracy: 50, usable: false, dragging: true), .dragging)
        XCTAssertEqual(zone(10, accuracy: 3, dragging: true), .dragging)
    }

    func testAFixTooPoorToUseShowsNoPlacement() {
        XCTAssertEqual(zone(20, accuracy: 50, usable: false), .unknown)
        XCTAssertEqual(zone(nil, accuracy: nil), .unknown)
    }

    /// 30 m with ±15 m could be outside a 40 m circle: near the edge, not a petrol 75 %.
    func testTheAccuracyMarginMovesTheBoatTowardTheEdge() {
        XCTAssertEqual(zone(30, accuracy: 15), .nearEdge)
        XCTAssertEqual(zone(20, accuracy: 5), .inside)
        XCTAssertEqual(zone(36, accuracy: 0), .nearEdge)
    }

    /// Outside only when even the near edge of the fix is beyond the radius.
    func testOutsideNeedsTheWholeFixBeyondTheRadius() {
        XCTAssertEqual(zone(44, accuracy: 3), .outside)
        XCTAssertEqual(zone(42, accuracy: 5), .nearEdge)
    }
}
