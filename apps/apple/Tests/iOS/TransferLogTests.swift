import XCTest

@testable import MadeGood

final class TransferLogTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TransferLogTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testEntriesAreNewestFirstAndFilterBySession() {
        let log = TransferLog(suiteName: suiteName)
        log.add("a", sessionId: "one", at: Date(timeIntervalSince1970: 1))
        log.add("b", sessionId: "two", at: Date(timeIntervalSince1970: 2))
        log.add("c", at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(log.recent().map(\.message), ["c", "b", "a"])
        XCTAssertEqual(log.recent(sessionId: "one").map(\.message), ["a"])
    }

    /// A failure logged in a background launch is still there when the user looks.
    func testTheLogSurvivesARelaunch() {
        TransferLog(suiteName: suiteName).add("stored", sessionId: "one")
        XCTAssertEqual(TransferLog(suiteName: suiteName).recent().map(\.message), ["stored"])
    }

    /// Review of #166, finding 1: entries added from several queues at once (the main
    /// thread and WatchConnectivity callbacks) all survive a relaunch; an older snapshot
    /// never overwrites a newer saved one.
    func testConcurrentWritersAllSurviveARelaunch() {
        let log = TransferLog(suiteName: suiteName)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            log.add("\(index)")
        }
        XCTAssertEqual(Set(TransferLog(suiteName: suiteName).recent().map(\.message)), Set((0..<100).map(String.init)))
    }

    func testTheLogKeepsOnlyTheNewestEntries() {
        let log = TransferLog(suiteName: suiteName)
        for index in 0..<(TransferLog.limit + 5) { log.add("\(index)") }
        let recent = log.recent()
        XCTAssertEqual(recent.count, TransferLog.limit)
        XCTAssertEqual(recent.first?.message, "\(TransferLog.limit + 4)")
        XCTAssertEqual(recent.last?.message, "5")
    }

    func testFilesAreDescribedWithExactSizes() {
        XCTAssertEqual(TransferLog.describe([:]), "none")
        XCTAssertEqual(
            TransferLog.describe(["meta.json": 300, "gps.ndjson.gz": 1_234]), "gps.ndjson.gz 1234 B, meta.json 300 B")
    }

    func testDeliveryGapsSayWhyTheWatchKeepsARecording() {
        let local: [String: Int64] = ["gps.ndjson.gz": 100, "meta.json": 300]
        XCTAssertEqual(RecordingTransfer.deliveryGaps(local: local, phone: local), [])
        XCTAssertEqual(
            RecordingTransfer.deliveryGaps(local: local, phone: ["gps.ndjson.gz": 99]),
            ["gps.ndjson.gz is 99 bytes on iPhone, 100 on the watch", "meta.json missing on iPhone"])
        XCTAssertEqual(RecordingTransfer.deliveryGaps(local: [:], phone: [:]), ["no recording files on the watch"])
        // The gaps and the delete decision always agree.
        for phone in [local, [:], ["gps.ndjson.gz": 99], ["meta.json": 300]] {
            XCTAssertEqual(
                RecordingTransfer.deliveryGaps(local: local, phone: phone).isEmpty,
                RecordingTransfer.isDelivered(local: local, phone: phone))
        }
    }
}
