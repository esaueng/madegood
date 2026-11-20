import WaterKit
import XCTest

@testable import MadeGood

final class SailingReadingsTests: XCTestCase {
    private func readings(side: WindEstimate.Side, vmg: Double, angle: Double) -> SailingReadings {
        let wind = WindEstimate(
            fromDegrees: 200, axisConfidence: 0.99, axisUncertainty: 3, legCourses: [160, 240], legAngle: 80,
            side: side)
        return SailingReadings(LiveSailing(wind: wind, tacks: 3, gybes: 0, vmg: vmg, trueWindAngle: angle))
    }

    /// Review regression: true wind 020°, gybing on 160°/240°, so the track estimate is 200°
    /// and its "tacks" are really gybes. Unresolved, nothing names a side.
    func testUnresolvedWindNamesOnlyTheAxis() {
        let unresolved = readings(side: .unresolved, vmg: 3.8, angle: 40)
        XCTAssertFalse(unresolved.resolved)
        XCTAssertEqual(unresolved.vmgTitle, "VMG")
        XCTAssertEqual(unresolved.windTitle, "Wind axis")
        XCTAssertEqual(unresolved.windText, "200°/020°")
        XCTAssertEqual(unresolved.angleTitle, "Off axis")
        XCTAssertEqual(unresolved.angleText, "40°")
        XCTAssertEqual(unresolved.maneuverRows.map(\.title), ["Tacks/gybes"])
        XCTAssertEqual(unresolved.maneuverRows.map(\.count), [3])
        XCTAssertEqual(readings(side: .priorInconclusive(290), vmg: 3.8, angle: 140).angleText, "40°")
        XCTAssertFalse(readings(side: .priorInconclusive(290), vmg: 3.8, angle: 40).resolved)

        let resolved = readings(side: .resolvedByPrior, vmg: 3.8, angle: 40)
        XCTAssertEqual(resolved.vmgTitle, "VMG upwind")
        XCTAssertEqual(resolved.windText, "200°")
        XCTAssertEqual(resolved.angleText, "40° stbd")
        XCTAssertEqual(resolved.maneuverRows.map(\.title), ["Tacks", "Gybes"])
        XCTAssertEqual(readings(side: .resolvedByPrior, vmg: -3.8, angle: 140).vmgTitle, "VMG downwind")
    }
}
