import Foundation
import XCTest

@testable import MadeGood

final class WorkoutMirrorStateTests: XCTestCase {
    func testAttachmentBlocksUntilStoppedOrExplicitlyDismissedAfterSilence() {
        let source = NSObject()
        let connection = ObjectIdentifier(source)
        let timestamp = Date(timeIntervalSince1970: 100)
        var state = WorkoutMirrorState()
        state.connect(connection, at: timestamp)
        XCTAssertTrue(state.isAttached)
        XCTAssertNil(state.connectedSnapshot)
        state.dismissIfStale(at: timestamp.addingTimeInterval(14))
        XCTAssertTrue(state.isAttached)
        let latest = snapshot(UUID(), sequence: 1)
        state.receive(latest, from: connection, at: timestamp.addingTimeInterval(10))
        state.dismissIfStale(at: timestamp.addingTimeInterval(20))
        XCTAssertEqual(state.connectedSnapshot, latest)
        state.dismissIfStale(at: timestamp.addingTimeInterval(25))
        XCTAssertFalse(state.isAttached)
        XCTAssertNil(state.connectedSnapshot)
        XCTAssertEqual(state.lastConfirmed, latest)
        state.stop(connection)
        XCTAssertNil(state.lastConfirmed)
    }

    func testDuplicateAndOutOfOrderSnapshotsDoNotReplaceReadings() throws {
        let source = NSObject()
        let connection = ObjectIdentifier(source)
        let id = UUID()
        var state = WorkoutMirrorState()
        state.connect(connection)
        let latest = snapshot(id, sequence: 3, elapsed: 30)
        let decoded = try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: JSONEncoder().encode(latest))
        state.receive(decoded, from: connection)
        state.receive(snapshot(id, sequence: 3, elapsed: 31), from: connection)
        state.receive(snapshot(id, sequence: 2, elapsed: 20), from: connection)
        state.receive(snapshot(UUID(), sequence: 4), from: connection)
        var unsupported = snapshot(id, sequence: 5)
        unsupported.version += 1
        state.receive(unsupported, from: connection)

        XCTAssertEqual(state.connectedSnapshot, latest)
        XCTAssertEqual(latest.age(at: latest.sentAt.addingTimeInterval(21)), 21)
    }

    func testReconnectNeedsFreshDataAndOldCallbacksCannotChangeTheMirror() {
        let firstSource = NSObject()
        let secondSource = NSObject()
        let first = ObjectIdentifier(firstSource)
        let second = ObjectIdentifier(secondSource)
        let id = UUID()
        var state = WorkoutMirrorState()
        let initial = snapshot(id, sequence: 10)
        state.connect(first)
        state.receive(initial, from: first)
        state.disconnect(first)
        state.receive(snapshot(id, sequence: 11), from: first)
        XCTAssertNil(state.connectedSnapshot)
        XCTAssertEqual(state.lastConfirmed, initial)

        state.connect(second)
        state.receive(initial, from: second)
        XCTAssertNil(state.connectedSnapshot)
        let refreshed = snapshot(id, sequence: 12)
        state.receive(refreshed, from: second)
        state.disconnect(first)
        state.stop(first)
        state.receive(snapshot(id, sequence: 20), from: first)
        XCTAssertEqual(state.connectedSnapshot, refreshed)
    }

    func testStoppedWorkoutCannotReturnAndLaterWorkoutCanStart() {
        let firstSource = NSObject()
        let secondSource = NSObject()
        let first = ObjectIdentifier(firstSource)
        let second = ObjectIdentifier(secondSource)
        let ended = UUID()
        var state = WorkoutMirrorState()
        state.connect(first)
        state.receive(snapshot(ended, sequence: 1), from: first)
        state.stop(first)
        state.receive(snapshot(ended, sequence: 2), from: first)
        XCTAssertNil(state.lastConfirmed)

        state.connect(second)
        state.receive(snapshot(ended, sequence: 3), from: second)
        XCTAssertNil(state.connectedSnapshot)
        let next = snapshot(UUID(), sequence: 1)
        state.receive(next, from: second)
        state.stop(first)
        XCTAssertEqual(state.connectedSnapshot, next)
        state.stop(second)
        XCTAssertNil(state.lastConfirmed)
    }

    func testReplacedWorkoutCannotReclaimAnotherConnection() {
        let firstSource = NSObject()
        let secondSource = NSObject()
        let thirdSource = NSObject()
        let first = ObjectIdentifier(firstSource)
        let second = ObjectIdentifier(secondSource)
        let third = ObjectIdentifier(thirdSource)
        var state = WorkoutMirrorState()
        let old = snapshot(UUID(), sequence: 1)
        state.connect(first)
        state.receive(old, from: first)

        let latest = snapshot(UUID(), sequence: 1)
        state.connect(second)
        state.receive(latest, from: second)
        state.connect(third)
        state.receive(snapshot(old.sessionID, sequence: 2), from: third)
        XCTAssertNil(state.connectedSnapshot)
        XCTAssertEqual(state.lastConfirmed, latest)
    }

    private func snapshot(_ id: UUID, sequence: UInt64, elapsed: Double = 0) -> WorkoutMirrorSnapshot {
        var readings = LiveReadings(nil)
        readings.elapsed = elapsed
        return WorkoutMirrorSnapshot(
            sessionID: id, sequence: sequence, sport: .kayak,
            sentAt: Date(timeIntervalSince1970: 100 + elapsed), readings: readings)
    }
}
