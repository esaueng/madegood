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

    /// Review of #170, finding 3: one part failed and another finished a second later; that
    /// success queued a send that resubmitted the failed part at once and cleared the failure
    /// count, so the backoff never held or grew. Acknowledgements and refreshes did the same.
    func testNothingGoesBeforeTheRetryIsDueAndEarlierPartsDoNotClearTheFailures() throws {
        var retry = RecordingTransfer.Retry()
        let due = try XCTUnwrap(retry.failed(now: now))
        XCTAssertEqual(due, now.addingTimeInterval(30))
        // Another part (queued before the failure) finishes a second later.
        let second = now.addingTimeInterval(1)
        retry.succeeded(now: second)
        XCTAssertEqual(retry.failures, 1)
        // The send it, an acknowledgement or a refresh asks for does not go...
        XCTAssertFalse(retry.allowsSend(now: second, userAsked: false))
        XCTAssertFalse(retry.allowsSend(now: due.addingTimeInterval(-1), userAsked: false))
        // ...unless the user asked ("Send again").
        XCTAssertTrue(retry.allowsSend(now: second, userAsked: true))
        // A part failing during the backoff does not start another retry or count again.
        XCTAssertNil(retry.failed(now: second))
        XCTAssertEqual(retry.failures, 1)

        // Due: sending resumes; it fails again, and the wait doubles.
        XCTAssertTrue(retry.allowsSend(now: due, userAsked: false))
        let again = try XCTUnwrap(retry.failed(now: due.addingTimeInterval(5)))
        XCTAssertEqual(again, due.addingTimeInterval(5 + 60))
        XCTAssertEqual(retry.failures, 2)
        // Only a success once the retry is due clears the failures.
        retry.succeeded(now: again.addingTimeInterval(-1))
        XCTAssertEqual(retry.failures, 2)
        retry.succeeded(now: again.addingTimeInterval(1))
        XCTAssertEqual(retry.failures, 0)
    }

    /// Re-check of #170, finding 4: retries lived only in memory, so a relaunch during a
    /// 30-minute backoff sent at once and the next failure started over at 30 s. They are
    /// saved and read back.
    func testARetryKeptAcrossALaunchStillHoldsAndCounts() throws {
        var retry = RecordingTransfer.Retry()
        for minute in 0..<7 { _ = retry.failed(now: now.addingTimeInterval(Double(minute) * 3600)) }
        let lastFailure = now.addingTimeInterval(6 * 3600)
        XCTAssertEqual(retry.at, lastFailure.addingTimeInterval(TransferPolicy.longestRetry))
        let saved = try JSONEncoder().encode(["s": retry])
        var loaded = try XCTUnwrap(JSONDecoder().decode([String: RecordingTransfer.Retry].self, from: saved)["s"])
        XCTAssertEqual(loaded, retry)
        // A relaunch ten minutes in still waits, and the next failure keeps the longest wait.
        let relaunch = lastFailure.addingTimeInterval(10 * 60)
        XCTAssertFalse(loaded.allowsSend(now: relaunch, userAsked: false))
        let afterDue = lastFailure.addingTimeInterval(TransferPolicy.longestRetry + 1)
        XCTAssertEqual(loaded.failed(now: afterDue), afterDue.addingTimeInterval(TransferPolicy.longestRetry))
        XCTAssertEqual(loaded.failures, 8)
    }

    /// The timer of a retry that ran late (the app was suspended) must not clear a later one.
    func testALateTimerDoesNotEndALaterRetry() throws {
        var retry = RecordingTransfer.Retry()
        let first = try XCTUnwrap(retry.failed(now: now))
        let second = try XCTUnwrap(retry.failed(now: first.addingTimeInterval(10)))
        retry.fired(first)
        XCTAssertEqual(retry.at, second)
        XCTAssertFalse(retry.allowsSend(now: first.addingTimeInterval(11), userAsked: false))
        retry.fired(second)
        XCTAssertNil(retry.at)
        XCTAssertTrue(retry.allowsSend(now: first.addingTimeInterval(11), userAsked: false))
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

    /// Review of #170, finding 5: a refresh request that failed left nothing to wake the app
    /// if a transfer then stalled without callbacks. The failed request is forgotten, so the
    /// next attempt (60 s later, a wake, or moving to the background) asks again.
    func testAFailedRefreshRequestIsAskedForAgain() {
        let failed = now.addingTimeInterval(15 * 60)
        let after = TransferPolicy.scheduledAfterFailure(current: failed, failed: failed)
        XCTAssertNil(after)
        let retryAt = now.addingTimeInterval(TransferPolicy.refreshRequestRetry)
        XCTAssertTrue(TransferPolicy.shouldSchedule(wanted: failed, scheduled: after, now: retryAt))
        // A newer request made meanwhile is kept: a late failure of an older one does not
        // erase it.
        let newer = now.addingTimeInterval(2 * 60)
        XCTAssertEqual(TransferPolicy.scheduledAfterFailure(current: newer, failed: failed), newer)
    }

    /// Re-check of #170, finding 3: the only retry after a failed request was a 60 s timer,
    /// which never fires if watchOS suspends the process first. It is asked again right away.
    func testAFailedRefreshRequestIsMadeAgainRightAwayAFewTimes() {
        let failed = now.addingTimeInterval(15 * 60)
        let attempts = (1...5).filter {
            TransferPolicy.retriesRefreshRequest(afterAttempt: $0, failed: failed, current: failed)
        }
        XCTAssertEqual(attempts, Array(1..<TransferPolicy.refreshRequestAttempts))
        // Not an older request that a newer one has replaced.
        XCTAssertFalse(
            TransferPolicy.retriesRefreshRequest(
                afterAttempt: 1, failed: failed, current: now.addingTimeInterval(60)))
        XCTAssertFalse(TransferPolicy.retriesRefreshRequest(afterAttempt: 1, failed: failed, current: nil))
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

    // MARK: Activation

    /// Review of #170, finding 2: an activation that failed left the session not activated
    /// with the delegate installed; background wakes in the same process only activated when
    /// the delegate was missing, so they waited in vain until the next launch.
    func testAFailedActivationIsTriedAgainByTheNextWake() {
        // Failed: completed with an error, so none is under way.
        XCTAssertTrue(
            TransferPolicy.shouldActivate(
                delegateInstalled: true, notActivated: true, activationStartedAt: nil, now: now))
        // Never activated in this process.
        XCTAssertTrue(
            TransferPolicy.shouldActivate(
                delegateInstalled: false, notActivated: true, activationStartedAt: nil, now: now))
    }

    func testAnActivationUnderWayOrDoneIsLeftAlone() {
        XCTAssertFalse(
            TransferPolicy.shouldActivate(
                delegateInstalled: true, notActivated: true, activationStartedAt: now.addingTimeInterval(-5),
                now: now))
        XCTAssertFalse(
            TransferPolicy.shouldActivate(
                delegateInstalled: true, notActivated: false, activationStartedAt: nil, now: now))
        // One that never completed is lost after the timeout.
        XCTAssertTrue(
            TransferPolicy.shouldActivate(
                delegateInstalled: true, notActivated: true,
                activationStartedAt: now.addingTimeInterval(-TransferPolicy.activationTimeout), now: now))
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

    /// The system's block, kept so a test can end the activity while the work runs.
    private final class Activity: @unchecked Sendable {
        var block: (@Sendable (Bool) -> Void)?
        let returned = XCTestExpectation(description: "the activity's block returned")
    }

    /// Review of #170, finding 4: the join started before the activity was held, and went on
    /// after it was denied or expired. Work now sees whether time is held, before and during.
    func testWorkKnowsWhetherBackgroundTimeIsHeld() {
        let activity = Activity()
        var seen: [BackgroundTime.State] = []
        BackgroundTime.run(
            "test",
            request: { _, block in
                activity.block = block
                block(false)
                activity.returned.fulfill()
            }
        ) { time in
            seen.append(time.current)
            // It runs out partway.
            activity.block?(true)
            seen.append(time.current)
        }
        XCTAssertEqual(seen, [.granted, .expired])
        // The activity is let go once the work is done.
        wait(for: [activity.returned], timeout: 2)
    }

    /// Re-check of #170, finding 2: when the activity let go after its longest hold, the work
    /// still saw the time as held.
    func testTheActivityLettingGoEndsTheTime() {
        var states: [BackgroundTime.State] = []
        BackgroundTime.run("test", request: { _, block in block(false) }, longestHold: 0.05) { time in
            states.append(time.current)
            let deadline = Date().addingTimeInterval(2)
            while time.hasTime, Date() < deadline { usleep(10_000) }
            states.append(time.current)
        }
        XCTAssertEqual(states, [.granted, .expired])
    }

    func testDeniedOrUnansweredTimeIsNotHeld() {
        var denied: Bool?
        BackgroundTime.run("test", request: { _, block in block(true) }) { denied = !$0.hasTime }
        XCTAssertEqual(denied, true)
        // No answer in time: the work runs (it must store the file) without time.
        var unanswered: BackgroundTime.State?
        BackgroundTime.run("test", request: { _, _ in }, answerTimeout: 0.05) { unanswered = $0.current }
        XCTAssertEqual(unanswered, .pending)
    }
}
