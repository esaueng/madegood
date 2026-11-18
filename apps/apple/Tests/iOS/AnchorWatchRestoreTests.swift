import CoreLocation
import XCTest
import WaterKit

@testable import MadeGood

/// Re-check regression: a relaunch restored the fix time saved at arming (or minutes
/// old) and raised "no GPS" at once; saved times on an old clock also hid new fixes.
@MainActor
final class AnchorWatchRestoreTests: XCTestCase {
    func testRestoredAlarmCountsGPSAsFreshFromLaunch() throws {
        var alarm = AnchorAlarm()
        XCTAssertTrue(alarm.set(latitude: 10, longitude: -30, radius: 40, at: 90_000))
        let data = try JSONEncoder().encode(alarm)

        // The new process's uptime clock is far behind the saved times.
        var restored = AnchorWatch.restored(from: data, at: 30)
        XCTAssertEqual(restored.state, .armed)
        XCTAssertEqual(restored.gpsLostDeadline, 150)
        XCTAssertFalse(restored.advance(to: 149))
        XCTAssertEqual(restored.state, .armed)
        // A fix on the new clock is accepted.
        restored.ingest(GPSFix(t: 31, latitude: 10, longitude: -30, horizontalAccuracy: 5))
        XCTAssertEqual(restored.lastFixTime, 31)
    }

    func testMissingOrUnreadableDataRestoresNothing() {
        XCTAssertEqual(AnchorWatch.restored(from: nil, at: 1).state, .clear)
        XCTAssertEqual(AnchorWatch.restored(from: Data("x".utf8), at: 1).state, .clear)
    }

    /// Extra-round regression: relaunching 119 s into an outage used to push the first
    /// no-GPS alert to about 239 s.
    func testRelaunchKeepsThePendingNoGPSTime() throws {
        var alarm = AnchorAlarm()
        XCTAssertTrue(alarm.set(latitude: 10, longitude: -30, radius: 40, at: 90_000))
        let data = try JSONEncoder().encode(alarm)
        let wallNow = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var restored = AnchorWatch.restored(
            from: data, at: 30, pendingNoGPS: wallNow.addingTimeInterval(1), wallNow: wallNow)
        XCTAssertEqual(restored.gpsLostDeadline, 31)
        XCTAssertTrue(restored.advance(to: 31))
        // A pending time later than the fresh grace period is not adopted.
        let later = AnchorWatch.restored(
            from: data, at: 30, pendingNoGPS: wallNow.addingTimeInterval(500), wallNow: wallNow)
        XCTAssertEqual(later.gpsLostDeadline, 150)
    }

    /// Extra-round regression: a cached fix up to 59 s old was stamped with the arrival
    /// time and could become the anchor.
    func testCachedFixesAreStampedWhenMeasured() throws {
        let wallNow = Date(timeIntervalSinceReferenceDate: 2_000_000)
        func location(age: TimeInterval, accuracy: Double = 5) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 10, longitude: -30), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: wallNow.addingTimeInterval(-age))
        }
        let cached = try XCTUnwrap(AnchorWatch.fix(from: location(age: 30), arrivedAt: 500, wallNow: wallNow))
        XCTAssertEqual(cached.t, 470)
        XCTAssertNil(AnchorAlarm.anchorPoint(from: [cached], at: 500))
        let current = try XCTUnwrap(AnchorWatch.fix(from: location(age: 1), arrivedAt: 500, wallNow: wallNow))
        XCTAssertEqual(current.t, 499)
        XCTAssertNotNil(AnchorAlarm.anchorPoint(from: [cached, current], at: 500))
        XCTAssertNil(AnchorWatch.fix(from: location(age: 90), arrivedAt: 500, wallNow: wallNow))
        XCTAssertNil(AnchorWatch.fix(from: location(age: 1, accuracy: -1), arrivedAt: 500, wallNow: wallNow))
        // A timestamp ahead of the wall clock counts as just measured, never as future.
        let ahead = try XCTUnwrap(AnchorWatch.fix(from: location(age: -5), arrivedAt: 500, wallNow: wallNow))
        XCTAssertEqual(ahead.t, 500)
    }
}
