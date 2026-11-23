import XCTest

@testable import MadeGood

/// Settings' upload totals. Simulator QA of #186: a session deleted from the account (HTTP
/// 410) never retries, yet Settings counted it as waiting to upload.
final class SessionSyncCountsTests: XCTestCase {
    func testASessionDeletedFromTheAccountIsNotWaiting() {
        let counts = SessionSyncCounts([.failed(.deletedFromCloud)])
        XCTAssertEqual(counts.waiting, 0)
        XCTAssertEqual(counts.problems, 0)
        XCTAssertEqual(counts.synced, 0)
        XCTAssertEqual(counts.deletedFromCloud, 1)
    }

    func testEachStatusCountsOnce() {
        let statuses: [SessionSyncStatus] = [
            .synced, .synced, .pending, .retrying(at: .distantFuture, offline: true),
            .retrying(at: .distantFuture, offline: false), .failed(.tooLarge), .failed(.deletedFromCloud),
        ]
        let counts = SessionSyncCounts(statuses)
        XCTAssertEqual(counts.synced, 2)
        // Pending and waiting for a connection.
        XCTAssertEqual(counts.waiting, 2)
        // A failed retry and a stopped upload.
        XCTAssertEqual(counts.problems, 2)
        XCTAssertEqual(counts.deletedFromCloud, 1)
        XCTAssertEqual(counts.synced + counts.waiting + counts.problems + counts.deletedFromCloud, statuses.count)
    }
}
