import CoreGraphics
import XCTest

@testable import MadeGood

final class WeatherSceneTests: XCTestCase {
    /// Regression: the boat was always drawn bow to the left, so in a west wind (the scene's
    /// default) it pointed head to wind while the clouds and waves ran the other way.
    func testBoatRunsBeforeTheWind() {
        for (from, downwind) in [(270.0, 1.0), (225, 1), (0, 1), (90, -1), (45, -1)] {
            let wind = SceneWind(windFrom: from)
            XCTAssertEqual(wind.sign, downwind, "wind from \(from)°")

            let transform = wind.boatTransform(at: CGPoint(x: 100, y: 50), angle: 0)
            let bow = CGPoint(x: -10, y: 0).applying(transform)
            let stern = CGPoint(x: 10, y: 0).applying(transform)
            let masthead = CGPoint(x: 0, y: -40).applying(transform)

            XCTAssertEqual((bow.x - stern.x).sign, downwind.sign, "bow points downwind, wind from \(from)°")
            XCTAssertEqual(masthead.x, 100, accuracy: 1e-9, "mast upright, wind from \(from)°")
            XCTAssertEqual(wind.wakeDirection, -downwind, "wake trails upwind, wind from \(from)°")
            XCTAssertEqual(wind.bowDirection, downwind)
        }
    }

    /// Reflections and the boat agree: the mirror faces the same way as the hull.
    func testHullScaleMatchesTheTransform() {
        for from in [90.0, 270] {
            let wind = SceneWind(windFrom: from)
            let bow = CGPoint(x: -10, y: 0).applying(wind.boatTransform(at: .zero, angle: 0))
            XCTAssertEqual(bow.x, -10 * wind.hullScale, accuracy: 1e-9)
        }
    }

    /// The boat stays level on flat water at any moment, and rocks only once there are waves.
    func testBoatIsLevelWithoutWaves() {
        for t in stride(from: 0.0, through: 60, by: 0.7) {
            XCTAssertEqual(BoatMotion.angle(slope: 0, sea: 0, t: t), 0, accuracy: 1e-12)
        }
        let rocking = stride(from: 0.0, through: 60, by: 0.7).map { BoatMotion.angle(slope: 0, sea: 1, t: $0) }
        XCTAssertGreaterThan(rocking.map(abs).max() ?? 0, 0.03)
        XCTAssertLessThanOrEqual(rocking.map(abs).max() ?? 0, BoatMotion.maxRock + 1e-12)
        // A wave under the hull tips it with the water: right end lower turns it clockwise.
        XCTAssertGreaterThan(BoatMotion.angle(slope: 0.3, sea: 0, t: 0), 0)
    }
}
