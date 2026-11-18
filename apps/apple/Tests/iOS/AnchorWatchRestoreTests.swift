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
}
