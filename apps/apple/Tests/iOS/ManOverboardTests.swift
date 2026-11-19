import Foundation
import WaterKit
import XCTest

@testable import MadeGood

/// The iPhone's man-overboard rules: guidance geometry (shared with the watch), following
/// the watch's mark in a mirrored session, and the mirror and Live Activity formats.
final class ManOverboardTests: XCTestCase {
    // A fake position in open water, like the anonymized fixtures.
    private let origin = (lat: 10.0, lon: -30.0)

    private func mark(at offset: (bearing: Double, distance: Double), markedAt: Double = 1_000) -> ManOverboard.Mark {
        let point = Geo.destination(
            lat: origin.lat, lon: origin.lon, bearing: offset.bearing, distance: offset.distance)
        let date = Date(timeIntervalSince1970: markedAt)
        return ManOverboard.Mark(
            latitude: point.lat, longitude: point.lon, markedAt: date, positionAt: date, positionAge: 0)
    }

    private func position(speed: Double?, course: Double?) -> ManOverboard.Position {
        ManOverboard.Position(
            latitude: origin.lat, longitude: origin.lon, at: Date(timeIntervalSince1970: 1_010), speed: speed,
            course: course)
    }

    // MARK: Guidance

    func testArrowIsRelativeToCourseWhileMoving() {
        let guidance = ManOverboard.guidance(from: position(speed: 2, course: 90), to: mark(at: (0, 200)))
        XCTAssertEqual(guidance.distance, 200, accuracy: 1)
        XCTAssertEqual(guidance.bearing, 0, accuracy: 0.5)
        XCTAssertTrue(guidance.isCourseRelative)
        // Mark due north while heading east: 90° to port.
        XCTAssertEqual(guidance.arrow, -90, accuracy: 0.5)
    }

    func testArrowPointsFromNorthWhenSlowOrWithoutCourse() {
        let target = mark(at: (225, 150))
        for fix in [
            position(speed: 0.4, course: 90), position(speed: 3, course: nil), position(speed: nil, course: 90),
        ] {
            let guidance = ManOverboard.guidance(from: fix, to: target)
            XCTAssertFalse(guidance.isCourseRelative)
            XCTAssertEqual(guidance.bearing, 225, accuracy: 0.5)
            XCTAssertEqual(guidance.arrow, guidance.bearing)
        }
    }

    // MARK: Following the watch

    func testANewWatchMarkIsAdopted() {
        let watch = mark(at: (0, 100))
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, previous: nil, local: nil, clearedMarkedAt: nil), .adopt(watch))
        // A newer watch mark replaces an older one on the phone.
        let older = mark(at: (90, 50), markedAt: 900)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, previous: nil, local: older, clearedMarkedAt: nil),
            .adopt(watch))
    }

    func testAMarkClearedOnThePhoneDoesNotComeBack() {
        let watch = mark(at: (0, 100))
        // The same snapshot mark again, after the phone cleared it.
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, previous: watch, local: nil, clearedMarkedAt: nil), .keep)
        // After a relaunch there is no previous snapshot; the cleared time still holds.
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(
                incoming: watch, previous: nil, local: nil, clearedMarkedAt: watch.markedAt), .keep)
    }

    func testANewerPhoneMarkIsKept() {
        let watch = mark(at: (0, 100), markedAt: 1_000)
        let phone = mark(at: (90, 30), markedAt: 1_100)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, previous: nil, local: phone, clearedMarkedAt: nil), .keep)
    }

    func testClearingOnTheWatchClearsTheMarkItGave() {
        let watch = mark(at: (0, 100))
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, previous: watch, local: watch, clearedMarkedAt: nil), .clear)
        // A mark of the phone's own stays.
        let phone = mark(at: (90, 30), markedAt: 1_100)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, previous: watch, local: phone, clearedMarkedAt: nil), .keep)
        // An older watch app never sends the field, so its snapshots change nothing.
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, previous: nil, local: phone, clearedMarkedAt: nil), .keep)
    }

    // MARK: Formats

    func testMirrorSnapshotsWithAndWithoutTheMarkDecode() throws {
        var readings = LiveReadings(nil)
        readings.speed = 2
        let old = WorkoutMirrorSnapshot(
            sessionID: UUID(), sequence: 1, sport: .sailing, sentAt: Date(timeIntervalSince1970: 1_000),
            readings: readings)
        let oldJSON = try JSONEncoder().encode(old)
        // An older watch app's snapshot has no such key at all.
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("manOverboard"))
        XCTAssertNil(try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: oldJSON).manOverboard)

        var new = old
        new.manOverboard = mark(at: (0, 100))
        let decoded = try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded, new)
        XCTAssertEqual(decoded.version, WorkoutMirrorSnapshot.currentVersion)
    }

    func testLiveActivityStateFromAnEarlierBuildDecodes() throws {
        let json = #"{"speed":"5.0 kn","speedNumber":"5.0","distance":"1.2 nm","movingTime":"0:12:00"}"#
        let state = try JSONDecoder().decode(SessionActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.manOverboard)
        XCTAssertNil(state.pauseLabel)
    }
}
