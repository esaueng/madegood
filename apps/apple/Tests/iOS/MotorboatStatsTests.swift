import XCTest
import WaterKit

@testable import MadeGood

final class MotorboatStatsTests: XCTestCase {
    private func recording(
        _ id: UUID = UUID(), sport: Sport = .motorboating, start: Double, distance: Double?
    ) -> MotorboatStats.Recording {
        MotorboatStats.Recording(
            sessionId: id, sport: sport, startedAt: start,
            folder: URL(fileURLWithPath: "/tmp/\(id.uuidString.lowercased())"), distance: distance)
    }

    /// Review regression: a phone recording's partial distance could be in the saved
    /// trips (the library reloads when a watch recording arrives) and was counted again
    /// on top of the live trip.
    func testLiveLogLeavesOutTheActiveAndInProgressRecordings() {
        let active = UUID()
        let writing = recording(start: 300, distance: 700)
        let recordings = [
            recording(start: 100, distance: 1852),
            recording(active, start: 200, distance: 500),
            writing,
            recording(sport: .kayak, start: 50, distance: 9000),
            recording(start: 60, distance: nil),
        ]
        let saved = MotorboatStats.savedTrips(recordings, excluding: active) { $0 == writing.folder }
        XCTAssertEqual(saved, [NauticalLog.Trip(startedAt: 100, distance: 1852)])
        XCTAssertEqual(NauticalLog(trip: 500, saved: saved).total, 2352)
    }

    /// Review regression: "Log to date" ordered trips by the trimmed start, so trimming A
    /// (started 10:00) to begin at 10:10 made B (started 10:05) lose A.
    func testLogToDateUsesOriginalRecordingStarts() {
        // A's original start is 36_000 (10:00); its trim is irrelevant to the log.
        let a = recording(start: 36_000, distance: 1852)
        let b = recording(start: 36_300, distance: 926)
        let saved = MotorboatStats.savedTrips([a, b], excluding: nil) { _ in false }
        let logB = NauticalLog(savedTrip: NauticalLog.Trip(startedAt: 36_300, distance: 926), all: saved)
        XCTAssertEqual(logB.total, 1852 + 926)
        let logA = NauticalLog(savedTrip: NauticalLog.Trip(startedAt: 36_000, distance: 1852), all: saved)
        XCTAssertEqual(logA.total, 1852)
    }
}
