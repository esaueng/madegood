import Foundation
import XCTest

@testable import MadeGood

@MainActor
final class AnchorGPSWatchdogTests: XCTestCase {
    func testReplacementKeepsTheCurrentAlarmUntilTheNewSlotIsScheduled() throws {
        typealias Schedule = AnchorGPSWatchdog.Schedule
        let fix = Date(timeIntervalSince1970: 0)
        let first = try XCTUnwrap(Schedule.renewal(fixTime: fix, pending: [:], sounding: []))
        XCTAssertEqual(first.deadline.timeIntervalSince(fix), 120)

        let pending = [first.id: first.deadline]
        XCTAssertNil(Schedule.renewal(fixTime: fix.addingTimeInterval(14), pending: pending, sounding: []))

        let nextFix = fix.addingTimeInterval(15)
        let replacement = try XCTUnwrap(Schedule.renewal(fixTime: nextFix, pending: pending, sounding: []))
        XCTAssertNotEqual(replacement.id, first.id)
        XCTAssertEqual(replacement.deadline.timeIntervalSince(nextFix), 120)
    }

    func testRenewalLeavesAnAlertingAlarmForTheUserToStop() throws {
        typealias Schedule = AnchorGPSWatchdog.Schedule
        let fix = Date(timeIntervalSince1970: 0)
        let first = try XCTUnwrap(Schedule.renewal(fixTime: fix, pending: [:], sounding: []))
        let next = try XCTUnwrap(Schedule.renewal(fixTime: fix, pending: [:], sounding: [first.id]))
        XCTAssertNotEqual(next.id, first.id)

        let later = fix.addingTimeInterval(15)
        let replacement = try XCTUnwrap(
            Schedule.renewal(fixTime: later, pending: [next.id: next.deadline], sounding: [first.id]))
        XCTAssertEqual(replacement.id, next.id)
        XCTAssertEqual(replacement.deadline.timeIntervalSince(later), 120)
    }
}
