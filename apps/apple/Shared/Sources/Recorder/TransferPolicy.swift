import Foundation

/// When and how much the watch sends of its recordings, kept apart from WatchConnectivity
/// and WatchKit so every decision is tested on iOS (docs/watch-transfer.md has the reasoning).
///
/// - Failed transfers go again after a backoff (`retryDelay`), not only at the next launch
///   or "Send again".
/// - While recordings wait, the watch keeps a background app refresh scheduled
///   (`nextRefresh`), so a suspended app wakes to queue the next parts, retry, and restart
///   stuck transfers even when no acknowledgement wakes it.
/// - A WatchConnectivity background task ends only once everything delivered is handled
///   (`backgroundWorkDone`).
/// - The window of parts queued per recording grows to cover a refresh interval of sending
///   when the watch has the space (`window`).
enum TransferPolicy {
    // MARK: Retry

    /// The wait before the first retry after a transfer fails.
    static let firstRetry: TimeInterval = 30
    /// The longest wait between retries.
    static let longestRetry: TimeInterval = 30 * 60

    /// The wait before sending again after `failures` failures in a row (at least 1):
    /// 30 s, 1, 2, 4, 8, 16 min, then every 30 min.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let doublings = min(max(failures, 1) - 1, 16)
        return min(firstRetry * pow(2, Double(doublings)), longestRetry)
    }

    // MARK: Background refresh

    /// The identifier of the watch's background app refresh for transfers (SwiftUI's
    /// `.appRefresh(_:)`; on watchOS the refresh's `userInfo`).
    static let refreshIdentifier = "app.madegood.transfer"
    /// How often a suspended watch app asks to wake while recordings wait. watchOS spaces
    /// refreshes at its discretion (an app on the watch face gets more of them).
    static let refreshInterval: TimeInterval = 15 * 60
    /// The soonest a refresh is asked for, so a due retry does not ask for "now".
    static let soonestRefresh: TimeInterval = 60

    /// When to wake next: never with nothing waiting; otherwise in `refreshInterval`, or at
    /// the next retry if that is sooner (but not sooner than `soonestRefresh`).
    static func nextRefresh(now: Date, hasPending: Bool, retryAt: Date?) -> Date? {
        guard hasPending else { return nil }
        let regular = now.addingTimeInterval(refreshInterval)
        guard let retryAt else { return regular }
        return min(regular, max(retryAt, now.addingTimeInterval(soonestRefresh)))
    }

    /// Whether to ask for a refresh at `wanted` when one is already asked for at
    /// `scheduled` (watchOS keeps one request; a new one replaces it). Keeps an earlier
    /// request still to come, so frequent sends do not push the wake further out.
    static func shouldSchedule(wanted: Date, scheduled: Date?, now: Date) -> Bool {
        guard let scheduled, scheduled > now else { return true }
        return wanted.addingTimeInterval(soonestRefresh) < scheduled
    }

    // MARK: WatchConnectivity background task

    /// The longest a WatchConnectivity background task waits for content before it ends
    /// anyway; watchOS ends it sooner when the task's time runs out.
    static let backgroundTaskLimit: TimeInterval = 20

    /// Whether a WatchConnectivity background task may end: the session is active, it has
    /// no content left to deliver, and no delivered content is still being handled.
    static func backgroundWorkDone(activated: Bool, hasContentPending: Bool, busy: Int) -> Bool {
        activated && !hasContentPending && busy == 0
    }

    // MARK: Activation

    /// How long an activation may go without completing before it is tried again.
    static let activationTimeout: TimeInterval = 30

    /// Whether to activate the WatchConnectivity session (again): when this object is not
    /// its delegate yet, or when it is not activated and no activation is under way (one that
    /// failed has completed with an error; one started `activationTimeout` ago without
    /// completing counts as lost). Without this, a failed activation lasted until the next
    /// launch, and every background wake in the process waited for it in vain.
    static func shouldActivate(
        delegateInstalled: Bool, notActivated: Bool, activationStartedAt: Date?, now: Date
    ) -> Bool {
        guard delegateInstalled else { return true }
        guard notActivated else { return false }
        guard let activationStartedAt else { return true }
        return abs(now.timeIntervalSince(activationStartedAt)) >= activationTimeout
    }

    // MARK: Window

    /// The most parts of a recording queued at once when the watch has room: about 16
    /// minutes of sending at the ~2 MB/min seen on device, so the queue lasts from one
    /// background wake to the next.
    static let largestWindow = 32
    /// The fewest parts queued, however little room is left, so a transfer always moves.
    static let smallestWindow = 2
    /// Free space left alone for recording the next session.
    static let reservedSpace: Int64 = 512 << 20

    /// The window for a watch with `freeSpace` bytes free (nil if unknown: the smallest):
    /// as many parts as fit above `reservedSpace`, between the smallest and largest window.
    static func window(freeSpace: Int64?, partSize: Int64 = TransferParts.partSize) -> Int {
        guard let freeSpace, partSize > 0 else { return smallestWindow }
        let fits = max(0, freeSpace - reservedSpace) / partSize
        return Int(min(Int64(largestWindow), max(Int64(smallestWindow), fits)))
    }
}
