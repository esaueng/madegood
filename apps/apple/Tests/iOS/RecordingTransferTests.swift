import XCTest

@testable import MadeGood

/// WatchConnectivity can leave a watch-to-phone file transfer outstanding forever. The watch
/// used to treat every outstanding transfer as in flight, so a stuck one was never sent
/// again, not even by "Send again", and the recording stayed "waiting for iPhone".
final class RecordingTransferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testATransferFromAnEarlierBuildIsQueuedAgain() {
        // Builds before this fix did not stamp transfers; theirs may be stuck.
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: nil, now: now, restart: false))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: ["sessionId": "x", "file": "meta.json"]))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: nil))
    }

    func testARecentTransferIsLeftToFinish() {
        let recent = now.addingTimeInterval(-(RecordingTransfer.stuckAfter - 1))
        XCTAssertFalse(RecordingTransfer.shouldRequeue(queuedAt: recent, now: now, restart: false))
        XCTAssertFalse(RecordingTransfer.shouldRequeue(queuedAt: now, now: now, restart: false))
    }

    func testAStuckTransferIsQueuedAgain() {
        let old = now.addingTimeInterval(-RecordingTransfer.stuckAfter)
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: old, now: now, restart: false))
        // A stamp far in the future (the clock was set back) does not pin it forever.
        let future = now.addingTimeInterval(RecordingTransfer.stuckAfter)
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: future, now: now, restart: false))
    }

    func testSendAgainQueuesEveryTransferAgain() {
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: now, now: now, restart: true))
    }

    func testTheQueuedTimeRoundTripsThroughMetadata() {
        let metadata: [String: Any] = ["queuedAt": now.timeIntervalSince1970]
        XCTAssertEqual(RecordingTransfer.queuedAt(metadata: metadata), now)
    }
}
