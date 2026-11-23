import XCTest

@testable import MadeGood

final class RecentlyDeletedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 86_400
    private var root: URL!
    private var history: URL!
    private var store: RecentlyDeleted!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        history = root.appendingPathComponent("Recordings", isDirectory: true)
        store = RecentlyDeleted(directory: root.appendingPathComponent("RecentlyDeleted", isDirectory: true))
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recording(_ name: String = UUID().uuidString.lowercased()) throws -> URL {
        let folder = history.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: folder.appendingPathComponent("gps.ndjson.gz"))
        return folder
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testADeletedRecordingLeavesHistoryWithItsFilesAndTheTime() throws {
        let folder = try recording()
        let entry = try store.moveIn(folder, now: now)

        XCTAssertFalse(exists(folder))
        XCTAssertTrue(exists(entry.recording.appendingPathComponent("gps.ndjson.gz")))
        XCTAssertEqual(store.list(), [entry])
        XCTAssertEqual(entry.folderName, folder.lastPathComponent)
        XCTAssertEqual(entry.deletedAt, now)
        XCTAssertEqual(entry.daysLeft(now: now), 30)
    }

    func testARecoveredRecordingReturnsToItsFolder() throws {
        let folder = try recording()
        let entry = try store.moveIn(folder, now: now)

        XCTAssertEqual(try store.restore(entry, to: history), folder)
        XCTAssertTrue(exists(folder.appendingPathComponent("gps.ndjson.gz")))
        XCTAssertFalse(exists(entry.container))
        XCTAssertEqual(store.list(), [])
    }

    /// The watch can send a recording again after the phone deleted it: recovering the
    /// deleted copy must not overwrite or merge into the one History shows.
    func testRecoveringNeverReplacesARecordingHistoryHasAgain() throws {
        let name = UUID().uuidString.lowercased()
        let entry = try store.moveIn(try recording(name), now: now)
        let again = try recording(name)
        try Data("newer".utf8).write(to: again.appendingPathComponent("meta.json"))

        XCTAssertThrowsError(try store.restore(entry, to: history)) { error in
            XCTAssertEqual(error as? RecentlyDeleted.RestoreError, .alreadyInHistory)
        }
        XCTAssertTrue(exists(entry.recording))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: again.path).sorted(), ["gps.ndjson.gz", "meta.json"])
    }

    func testTheSameSessionDeletedTwiceKeepsBothCopies() throws {
        let name = UUID().uuidString.lowercased()
        try store.moveIn(try recording(name), now: now)
        try store.moveIn(try recording(name), now: now.addingTimeInterval(60))

        let listed = store.list()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.folderName)), [name])
        XCTAssertEqual(listed.first?.deletedAt, now.addingTimeInterval(60), "most recently deleted first")
    }

    func testRecordingsExpireThirtyDaysAfterTheyWereDeleted() throws {
        let old = try store.moveIn(try recording(), now: now.addingTimeInterval(-30 * day))
        let recent = try store.moveIn(try recording(), now: now.addingTimeInterval(-30 * day + 1))

        XCTAssertEqual(store.expired(now: now), [old])
        XCTAssertEqual(recent.daysLeft(now: now), 1)
        XCTAssertEqual(recent.daysLeft(now: recent.deletedAt), 30)
        XCTAssertEqual(recent.daysLeft(now: recent.deletedAt.addingTimeInterval(1)), 30)
        XCTAssertEqual(recent.daysLeft(now: recent.deletedAt.addingTimeInterval(day)), 29)
    }

    func testRemovingDeletesTheRecordingForGood() throws {
        let entry = try store.moveIn(try recording(), now: now)
        try store.remove(entry)
        XCTAssertFalse(exists(entry.container))
        XCTAssertEqual(store.list(), [])
    }

    /// A stop between writing the info file and the move leaves a folder with no recording;
    /// one a newer app wrote is left alone.
    func testAbandonedFoldersAreClearedButNewerOnesKept() throws {
        let kept = try store.moveIn(try recording(), now: now)
        let empty = store.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(#"{"version":1,"folder":"x","deletedAt":0}"#.utf8)
            .write(to: empty.appendingPathComponent(RecentlyDeleted.infoName))
        let newer = store.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data(#"{"version":2,"folder":"x","deletedAt":0}"#.utf8)
            .write(to: newer.appendingPathComponent(RecentlyDeleted.infoName))

        store.removeAbandoned()

        XCTAssertFalse(exists(empty))
        XCTAssertTrue(exists(newer))
        XCTAssertEqual(store.list(), [kept])
        XCTAssertEqual(store.expired(now: .distantFuture), [kept], "a newer app's folder never expires here")
    }

    /// Review finding: a demo library's trash inside the app's own was cleared by the app's
    /// scan as abandoned, with every recording in it.
    func testTheAppsScanNeverReachesADemoLibrarysDeletedRecordings() throws {
        let app = RecentlyDeleted(directory: RecentlyDeleted.directory(in: root, demoNamespace: nil))
        let demo = RecentlyDeleted(directory: RecentlyDeleted.directory(in: root, demoNamespace: UUID()))
        let entry = try demo.moveIn(try recording(), now: now)

        app.removeAbandoned()

        XCTAssertEqual(demo.list(), [entry])
        XCTAssertEqual(app.list(), [])
    }

    func testAFailedMoveLeavesNothingBehind() throws {
        let missing = history.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try store.moveIn(missing, now: now))
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [], [])
    }
}
