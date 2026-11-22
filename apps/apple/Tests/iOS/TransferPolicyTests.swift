import XCTest

@testable import MadeGood

/// When the watch sends, retries and wakes in the background (docs/watch-transfer.md).
final class TransferPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Retry

    /// A failed transfer used to wait for the next launch or "Send again".
    func testAFailedTransferGoesAgainAfterABackoffThatDoublesUpToHalfAnHour() {
        let delays = (1...8).map { TransferPolicy.retryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [30, 60, 120, 240, 480, 960, 1800, 1800])
        XCTAssertEqual(TransferPolicy.retryDelay(afterFailures: 0), 30)
        XCTAssertEqual(TransferPolicy.retryDelay(afterFailures: 10_000), TransferPolicy.longestRetry)
    }

    func testOnlyACancellationIsNoReasonToRetry() {
        XCTAssertTrue(RecordingTransfer.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        // WCErrorCodeTransferTimedOut, WCErrorCodeNotReachable, WCErrorCodeCompanionAppNotInstalled.
        for code in [7017, 7007, 7018] {
            XCTAssertFalse(RecordingTransfer.isCancellation(NSError(domain: "WCErrorDomain", code: code)))
        }
        XCTAssertFalse(
            RecordingTransfer.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testWaitsAreLoggedInSecondsOrMinutes() {
        XCTAssertEqual(RecordingTransfer.describe(30), "30 s")
        XCTAssertEqual(RecordingTransfer.describe(60), "60 s")
        XCTAssertEqual(RecordingTransfer.describe(120), "2 min")
        XCTAssertEqual(RecordingTransfer.describe(15 * 60), "15 min")
    }

    // MARK: Background refresh

    func testNoRefreshIsAskedForWithNothingWaiting() {
        XCTAssertNil(TransferPolicy.nextRefresh(now: now, hasPending: false, retryAt: now.addingTimeInterval(60)))
    }

    func testAWaitingRecordingWakesTheAppEveryRefreshInterval() {
        XCTAssertEqual(
            TransferPolicy.nextRefresh(now: now, hasPending: true, retryAt: nil),
            now.addingTimeInterval(TransferPolicy.refreshInterval))
        // A retry due later than that does not hold the refresh back.
        XCTAssertEqual(
            TransferPolicy.nextRefresh(now: now, hasPending: true, retryAt: now.addingTimeInterval(30 * 60)),
            now.addingTimeInterval(TransferPolicy.refreshInterval))
    }

    /// A suspended app's retry timer does not fire: the refresh wakes it when the retry is due.
    func testARetryDueSoonerBringsTheRefreshForward() {
        XCTAssertEqual(
            TransferPolicy.nextRefresh(now: now, hasPending: true, retryAt: now.addingTimeInterval(120)),
            now.addingTimeInterval(120))
        // Due now or overdue: as soon as watchOS allows, not "now".
        XCTAssertEqual(
            TransferPolicy.nextRefresh(now: now, hasPending: true, retryAt: now.addingTimeInterval(-600)),
            now.addingTimeInterval(TransferPolicy.soonestRefresh))
    }

    /// watchOS keeps one request; asking again replaces it. Sends happen with every part, so
    /// each must not push the wake further out.
    func testAnEarlierRequestStillToComeIsKept() {
        let scheduled = now.addingTimeInterval(10 * 60)
        XCTAssertFalse(
            TransferPolicy.shouldSchedule(wanted: now.addingTimeInterval(15 * 60), scheduled: scheduled, now: now))
        XCTAssertFalse(
            TransferPolicy.shouldSchedule(wanted: scheduled.addingTimeInterval(-30), scheduled: scheduled, now: now))
        // A retry due sooner replaces it.
        XCTAssertTrue(
            TransferPolicy.shouldSchedule(wanted: now.addingTimeInterval(2 * 60), scheduled: scheduled, now: now))
        // None asked for this launch, or the one asked for has passed (it fired, or watchOS
        // let it go).
        XCTAssertTrue(TransferPolicy.shouldSchedule(wanted: scheduled, scheduled: nil, now: now))
        XCTAssertTrue(
            TransferPolicy.shouldSchedule(
                wanted: now.addingTimeInterval(15 * 60), scheduled: now.addingTimeInterval(-1), now: now))
    }

    // MARK: WatchConnectivity background task

    /// The task must stay open until the session has delivered everything and the app has
    /// handled it, including queuing the next parts; ending sooner lets watchOS suspend the
    /// app before the window is topped up.
    func testABackgroundWakeEndsOnlyOnceEverythingDeliveredIsHandled() {
        XCTAssertTrue(TransferPolicy.backgroundWorkDone(activated: true, hasContentPending: false, busy: 0))
        XCTAssertFalse(TransferPolicy.backgroundWorkDone(activated: false, hasContentPending: false, busy: 0))
        XCTAssertFalse(TransferPolicy.backgroundWorkDone(activated: true, hasContentPending: true, busy: 0))
        XCTAssertFalse(TransferPolicy.backgroundWorkDone(activated: true, hasContentPending: false, busy: 1))
    }

    // MARK: Window

    func testTheWindowCoversARefreshIntervalOfSendingWhenThereIsRoom() {
        let mib: Int64 = 1 << 20
        XCTAssertEqual(TransferPolicy.window(freeSpace: 8 << 30), TransferPolicy.largestWindow)
        // 32 parts at ~2 MB/min last longer than the interval between refreshes.
        XCTAssertGreaterThan(
            Double(TransferPolicy.largestWindow) * Double(TransferParts.partSize) / (2_000_000 / 60),
            TransferPolicy.refreshInterval)
        XCTAssertEqual(TransferPolicy.window(freeSpace: TransferPolicy.reservedSpace + 5 * mib), 5)
    }

    func testTheWindowShrinksWithLittleRoomButNeverStopsSending() {
        XCTAssertEqual(TransferPolicy.window(freeSpace: TransferPolicy.reservedSpace), TransferPolicy.smallestWindow)
        XCTAssertEqual(TransferPolicy.window(freeSpace: 0), TransferPolicy.smallestWindow)
        XCTAssertEqual(TransferPolicy.window(freeSpace: nil), TransferPolicy.smallestWindow)
        XCTAssertEqual(TransferPolicy.window(freeSpace: 8 << 30, partSize: 0), TransferPolicy.smallestWindow)
    }

    // MARK: Phone

    func testWorkWithBackgroundTimeRunsBeforeReturning() {
        var ran = false
        RecordingTransfer.withBackgroundTime("test") { ran = true }
        XCTAssertTrue(ran)
    }
}
