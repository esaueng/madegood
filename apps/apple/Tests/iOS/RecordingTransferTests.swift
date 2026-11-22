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

    func testATransferFromAnEarlierBuildIsQueuedAgainAtLaunch() {
        // Builds before this fix did not stamp transfers; theirs may be stuck.
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: nil, now: now, requeue: .stuck))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: ["sessionId": "x", "file": "meta.json"]))
        XCTAssertNil(RecordingTransfer.queuedAt(metadata: nil))
    }

    func testARecentTransferIsLeftToFinish() {
        let recent = now.addingTimeInterval(-(RecordingTransfer.stuckAfter - 1))
        XCTAssertFalse(RecordingTransfer.shouldRequeue(queuedAt: recent, now: now, requeue: .stuck))
        XCTAssertFalse(RecordingTransfer.shouldRequeue(queuedAt: now, now: now, requeue: .stuck))
    }

    func testAStuckTransferIsQueuedAgainAtLaunch() {
        let old = now.addingTimeInterval(-RecordingTransfer.stuckAfter)
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: old, now: now, requeue: .stuck))
        // A stamp far in the future (the clock was set back) does not pin it forever.
        let future = now.addingTimeInterval(RecordingTransfer.stuckAfter)
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: future, now: now, requeue: .stuck))
    }

    func testOnlyALaunchOrSendAgainCancelsATransfer() {
        // Settings updates send too; they never restart a transfer that may be progressing.
        XCTAssertFalse(RecordingTransfer.shouldRequeue(queuedAt: nil, now: now, requeue: .none))
        XCTAssertTrue(RecordingTransfer.shouldRequeue(queuedAt: now, now: now, requeue: .all))
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
