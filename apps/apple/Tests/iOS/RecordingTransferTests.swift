import WaterKit
import XCTest

@testable import MadeGood

final class RecordingTransferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Stuck transfers

    // WatchConnectivity can leave a watch-to-phone file transfer outstanding forever. The
    // watch used to treat every outstanding transfer as in flight, so a stuck one was never
    // sent again, not even by "Send again", and the recording stayed "waiting for iPhone".

    private func requeue(
        queuedMinutesAgo: Double?, progress: Bool = false, movedMinutesAgo: Double? = nil,
        _ mode: RecordingTransfer.Requeue
    ) -> Bool {
        RecordingTransfer.shouldRequeue(
            oldestQueuedAt: queuedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, anyProgress: progress,
            progressSince: movedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, now: now, requeue: mode)
    }

    func testATransferFromAnEarlierBuildIsQueuedAgainAtLaunchIfItNeverStarted() {
        // Builds before stamps did not record when a transfer was queued; it may be stuck.
        XCTAssertTrue(requeue(queuedMinutesAgo: nil, .stuck))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: ["sessionId": "x", "file": "meta.json"]))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: nil))
    }

    func testARecentTransferIsLeftToFinish() {
        XCTAssertFalse(requeue(queuedMinutesAgo: RecordingTransfer.stuckAfter / 60 - 1, .stuck))
        XCTAssertFalse(requeue(queuedMinutesAgo: 0, .stuck))
    }

    func testAStuckTransferIsQueuedAgainAtLaunch() {
        XCTAssertTrue(requeue(queuedMinutesAgo: RecordingTransfer.stuckAfter / 60, .stuck))
        // A stamp far in the future (the clock was set back) does not pin it forever.
        XCTAssertTrue(requeue(queuedMinutesAgo: -RecordingTransfer.stuckAfter / 60, .stuck))
    }

    func testSettingsUpdatesNeverCancelATransfer() {
        XCTAssertFalse(requeue(queuedMinutesAgo: nil, .none))
        XCTAssertFalse(requeue(queuedMinutesAgo: 60, progress: true, movedMinutesAgo: 30, .none))
    }

    /// Seen on device after #165: a 35 MB motion stream was 23% sent after 4 minutes, and
    /// every launch or "Send again" cancelled it and started it over, so the recording never
    /// arrived. A transfer that is moving is never cancelled.
    func testATransferThatIsMovingIsNeverCancelled() {
        // A launch sees a started transfer for the first time: it may be moving.
        XCTAssertFalse(requeue(queuedMinutesAgo: 32, progress: true, movedMinutesAgo: 0, .stuck))
        XCTAssertFalse(requeue(queuedMinutesAgo: nil, progress: true, movedMinutesAgo: 0, .stuck))
        // "Send again" while it moves.
        XCTAssertFalse(requeue(queuedMinutesAgo: 4, progress: true, movedMinutesAgo: 1, .all))
        // A launch or refresh does not cancel a started transfer that moved recently.
        XCTAssertFalse(requeue(queuedMinutesAgo: 60, progress: true, movedMinutesAgo: 10, .stuck))
    }

    /// Review of #170, finding 1: a part that stopped at 40% and stayed outstanding without
    /// a callback was never restarted by a launch or background refresh (only "Send again"
    /// did), and with the window full nothing else was queued: the recording stalled.
    func testAStartedTransferFlatForStuckAfterIsRestartedByARefresh() {
        let stuck = RecordingTransfer.stuckAfter / 60
        XCTAssertTrue(requeue(queuedMinutesAgo: 60, progress: true, movedMinutesAgo: stuck, .stuck))
        XCTAssertFalse(requeue(queuedMinutesAgo: 60, progress: true, movedMinutesAgo: stuck - 1, .stuck))
        // Started, but never seen moving: no clock to go by, so it is left alone.
        XCTAssertFalse(requeue(queuedMinutesAgo: 60, progress: true, movedMinutesAgo: nil, .stuck))
    }

    /// Background wakes are separate short looks, often in new processes: the tracker is kept
    /// across them, so a later look sees that the progress has not changed since an earlier one.
    func testProgressFlatAcrossLaunchesCountsAsStuck() throws {
        var first = RecordingTransfer.ProgressTracker()
        let key = "motion.ndjson.gz#3#1000.0"
        XCTAssertEqual(first.observe([(key: key, fraction: 0.4)], now: now).since, now)
        // Saved, then read back by a later launch.
        let saved = try JSONEncoder().encode(["s": first])
        var later = try XCTUnwrap(
            JSONDecoder().decode([String: RecordingTransfer.ProgressTracker].self, from: saved)["s"])
        let afterStuck = now.addingTimeInterval(RecordingTransfer.stuckAfter)
        let seen = later.observe([(key: key, fraction: 0.4)], now: afterStuck)
        XCTAssertEqual(seen.since, now)
        XCTAssertTrue(
            RecordingTransfer.shouldRequeue(
                oldestQueuedAt: now, anyProgress: seen.anyProgress, progressSince: seen.since, now: afterStuck,
                requeue: .stuck))
        // Had it grown in between, it would be moving.
        var grown = try XCTUnwrap(
            JSONDecoder().decode([String: RecordingTransfer.ProgressTracker].self, from: saved)["s"])
        XCTAssertEqual(grown.observe([(key: key, fraction: 0.5)], now: afterStuck).since, afterStuck)
        // A fresh tracker (nothing saved) treats a started transfer as moving: no cancel.
        var fresh = RecordingTransfer.ProgressTracker()
        let firstLook = fresh.observe([(key: key, fraction: 0.4)], now: afterStuck)
        XCTAssertFalse(
            RecordingTransfer.shouldRequeue(
                oldestQueuedAt: now, anyProgress: true, progressSince: firstLook.since, now: afterStuck,
                requeue: .stuck))
    }

    func testSendAgainRestartsATransferThatStalledOrNeverStarted() {
        let stalled = RecordingTransfer.stalledAfter / 60
        XCTAssertTrue(requeue(queuedMinutesAgo: 10, progress: true, movedMinutesAgo: stalled, .all))
        XCTAssertTrue(requeue(queuedMinutesAgo: 0, progress: false, movedMinutesAgo: 0, .all))
    }

    /// Review of #167, finding 4: a look before anything was queued must not start the
    /// stall clock for a transfer first seen moving minutes later.
    func testATransferFirstSeenMovingCountsAsMoving() {
        var tracker = RecordingTransfer.ProgressTracker()
        XCTAssertFalse(tracker.observe([], now: now).anyProgress)
        let later = now.addingTimeInterval(3 * 60)
        let seen = tracker.observe([(key: "motion#0", fraction: 0.2)], now: later)
        XCTAssertTrue(seen.anyProgress)
        XCTAssertEqual(seen.since, later)
        XCTAssertFalse(
            RecordingTransfer.shouldRequeue(
                oldestQueuedAt: now, anyProgress: true, progressSince: seen.since, now: later, requeue: .all))
    }

    func testATransferThatStopsGrowingCountsAsStalled() {
        var tracker = RecordingTransfer.ProgressTracker()
        _ = tracker.observe([(key: "motion#0", fraction: 0.2)], now: now)
        let later = now.addingTimeInterval(RecordingTransfer.stalledAfter)
        let seen = tracker.observe([(key: "motion#0", fraction: 0.2)], now: later)
        XCTAssertEqual(seen.since, now)
        XCTAssertTrue(
            RecordingTransfer.shouldRequeue(
                oldestQueuedAt: now, anyProgress: true, progressSince: seen.since, now: later, requeue: .all))
        // Growth, or a finished part, counts as moving again.
        XCTAssertEqual(tracker.observe([(key: "motion#0", fraction: 0.3)], now: later).since, later)
        tracker.finished(at: later.addingTimeInterval(1))
        XCTAssertEqual(tracker.lastChange, later.addingTimeInterval(1))
    }

    func testTheQueuedTimeRoundTripsThroughMetadata() {
        let metadata: [String: Any] = ["queuedAt": now.timeIntervalSince1970]
        XCTAssertEqual(RecordingTransfer.queuedAt(metadata: metadata), now)
    }

    // MARK: Deleting on the watch

    func testTheWatchDeletesOnlyWhenThePhoneHoldsEveryFileAtTheSameSize() {
        let local: [String: Int64] = ["gps.ndjson.gz": 100, "motion.ndjson.gz": 2000, "meta.json": 300]
        XCTAssertTrue(RecordingTransfer.isDelivered(local: local, phone: local))
        XCTAssertTrue(RecordingTransfer.isDelivered(local: local, phone: local.merging(["hr.ndjson.gz": 5]) { $1 }))
        XCTAssertFalse(RecordingTransfer.isDelivered(local: local, phone: local.filter { $0.key != "meta.json" }))
        XCTAssertFalse(RecordingTransfer.isDelivered(local: local, phone: local.merging(["gps.ndjson.gz": 99]) { $1 }))
        XCTAssertFalse(RecordingTransfer.isDelivered(local: [:], phone: [:]))
    }

    /// Review of the stuck-transfer fix, finding 1: the phone acknowledged the streams of a
    /// half-received recording, the user deleted it, and then only `meta.json` arrived. Adding
    /// acknowledgements up let the watch delete a recording the phone no longer had.
    func testAPartialCopyDeletedOnThePhoneDoesNotDeleteTheWatchCopy() throws {
        let phoneFolder = root.appendingPathComponent("phone", isDirectory: true)
        try FileManager.default.createDirectory(at: phoneFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: phoneFolder.appendingPathComponent("gps.ndjson.gz"))
        let local: [String: Int64] = ["gps.ndjson.gz": 10, "meta.json": 4]
        let first = try XCTUnwrap(RecordingTransfer.recordingFiles(in: phoneFolder))
        XCTAssertFalse(RecordingTransfer.isDelivered(local: local, phone: first))

        // The user deletes the "Receiving…" row; then the late meta.json is stored alone.
        try FileManager.default.removeItem(at: phoneFolder)
        try FileManager.default.createDirectory(at: phoneFolder, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: phoneFolder.appendingPathComponent("meta.json"))
        let latest = try XCTUnwrap(RecordingTransfer.recordingFiles(in: phoneFolder))
        XCTAssertEqual(latest, ["meta.json": 4])
        XCTAssertFalse(RecordingTransfer.isDelivered(local: local, phone: latest))
    }

    /// Finding 2: a failed replace can move a stored file out of place. The list reflects
    /// what is at the recording's paths, so the watch keeps its copy.
    func testTheListCountsOnlyRecordingFilesInPlace() throws {
        let folder = root.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 3).write(to: folder.appendingPathComponent("meta.json"))
        try Data(count: 7).write(to: folder.appendingPathComponent(".incoming-x-gps.ndjson.gz"))
        try Data(count: 9).write(to: folder.appendingPathComponent(RecordingStore.trackFileName))
        XCTAssertEqual(RecordingTransfer.recordingFiles(in: folder), ["meta.json": 3])
        XCTAssertNil(RecordingTransfer.recordingFiles(in: root.appendingPathComponent("missing")))
    }

    /// Re-check finding 2: the last file of a "Receiving…" recording arrives (and the phone
    /// acknowledges a complete list) just before the user deletes the still-visible row.
    /// The phone must not delete what the user did not see, or the watch deletes its copy too.
    @MainActor
    func testThePhoneDoesNotDeleteARecordingThatChangedSinceItWasShown() throws {
        let folder = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appendingPathComponent("gps.ndjson.gz"))
        let shown = SessionLibrary.Item(
            entry: RecordingStore.Entry(folder: folder, meta: nil, revision: RawSessionReader.revision(of: folder)))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meta.json"))

        XCTAssertThrowsError(try SessionLibrary().delete(shown))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path))
    }

    func testAnAcknowledgementWithoutAListNeverDeletes() {
        // A phone build from before the list sends only the file name.
        XCTAssertNil(
            RecordingTransfer.phoneFiles(fromAcknowledgement: ["stored": true, "sessionId": "x", "file": "meta.json"]))
        XCTAssertNil(RecordingTransfer.phoneFiles(fromAcknowledgement: ["files": ["meta.json": "big"]]))
        let files: [String: Int64] = ["meta.json": 300, "gps.ndjson.gz": 100]
        // As WatchConnectivity delivers it: a property list of NSNumbers.
        let delivered: [String: Any] = ["files": files.mapValues { NSNumber(value: $0) }]
        XCTAssertEqual(RecordingTransfer.phoneFiles(fromAcknowledgement: delivered), files)
    }
}
