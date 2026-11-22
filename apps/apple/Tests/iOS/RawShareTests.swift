import Synchronization
import WaterKit
import XCTest

@testable import MadeGood

/// Review of #87: what leaves the phone and the watch for raw format 2.
final class RawShareTests: XCTestCase {
    private var root: URL!
    private let start = 946_684_800.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RawShareTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func meta() -> RawFormat.Meta {
        RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: start, endedAt: start + 10,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
    }

    /// A version 1 recording as an interrupted watch transfer leaves it on the phone.
    private func interruptedV1(named name: String = UUID().uuidString.lowercased()) throws -> URL {
        let folder = root.appendingPathComponent("Recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: 5_000))
            .write(to: folder.appendingPathComponent("meta.json"))
        let motion = try RawFormat.line(
            RawFormat.MotionLine(
                ts: 5_000.5, userAcceleration: .zero, gravity: .zero, rotationRate: .zero, attitude: .identity))
        try Gzip.compress(motion).write(to: folder.appendingPathComponent("motion.ndjson.gz"))
        // The staging copy a stopped transfer left behind: raw uptime in a clock line.
        try Gzip.compress(RawFormat.line(RawFormat.V1.ClockAnchor(unix: start, uptime: 5_000)))
            .write(to: folder.appendingPathComponent("\(RecordingStore.stagingPrefix)\(UUID().uuidString)-clock.ndjson.gz"))
        return folder
    }

    private func allText(in folder: URL) throws -> String {
        var text = ""
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            text += String(decoding: Gzip.isGzipped(data) ? try Gzip.decompress(data) : data, as: UTF8.self)
        }
        return text
    }

    func testAnInterruptedTransferNeverReachesASharedRecording() async throws {
        let folder = try interruptedV1()
        let prepared = try await ZipExport.preparedRecording(folder: folder, root: root.appendingPathComponent("Shared"))
        let names = try FileManager.default.contentsOfDirectory(atPath: prepared.path).sorted()
        XCTAssertEqual(names, ["meta.json", "motion.ndjson.gz"])
        XCTAssertFalse(try allText(in: prepared).contains("uptime"))
        XCTAssertEqual(try RawSessionReader.readMeta(folder: prepared).version, RawFormat.version)
    }

    func testPreparedRecordingsAreCachedPerRevision() async throws {
        let folder = try interruptedV1()
        let cache = root.appendingPathComponent("Shared")
        let calls = Mutex(0)
        let first = try await ZipExport.preparedRecording(folder: folder, root: cache) { _ in calls.withLock { $0 += 1 } }
        let converting = calls.withLock { $0 }
        XCTAssertGreaterThan(converting, 1)
        let again = try await ZipExport.preparedRecording(folder: folder, root: cache) { _ in calls.withLock { $0 += 1 } }
        XCTAssertEqual(again, first)
        XCTAssertEqual(calls.withLock { $0 }, converting + 1, "the cached copy is reused, not converted again")

        // A changed recording gets a new copy, and the old one goes.
        try Data("{\"ts\":1}\n".utf8).write(to: folder.appendingPathComponent("events.ndjson"))
        let changed = try await ZipExport.preparedRecording(folder: folder, root: cache)
        XCTAssertNotEqual(changed, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    // Scoped re-check of #87.

    /// Finding 2: deleting a recording removes its prepared copies; launch prunes copies of
    /// recordings that are gone, and old leftovers of an interrupted preparation.
    func testPreparedCopiesGoWithTheirRecording() async throws {
        let cache = root.appendingPathComponent("Shared")
        let kept = try interruptedV1()
        let deleted = try interruptedV1()
        _ = try await ZipExport.preparedRecording(folder: kept, root: cache)
        _ = try await ZipExport.preparedRecording(folder: deleted, root: cache)
        ZipExport.removePrepared(for: deleted, root: cache)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [kept.lastPathComponent])

        let gone = try interruptedV1()
        _ = try await ZipExport.preparedRecording(folder: gone, root: cache)
        let fresh = cache.appendingPathComponent(".partial-fresh", isDirectory: true)
        let stale = cache.appendingPathComponent(".partial-stale", isDirectory: true)
        for url in [fresh, stale] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: stale.path)
        ZipExport.prunePrepared(keeping: [kept.lastPathComponent], root: cache)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted(),
            [".partial-fresh", kept.lastPathComponent].sorted())
    }

    /// Finding 3: concurrent shares of one recording prepare it once and all succeed.
    func testConcurrentPreparationsOfOneRecordingAllSucceed() async throws {
        let folder = try interruptedV1()
        let cache = root.appendingPathComponent("Shared")
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<6 { group.addTask { try await ZipExport.preparedRecording(folder: folder, root: cache) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(results).count, 1)
        let prepared = try XCTUnwrap(results.first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prepared.path).sorted(), ["meta.json", "motion.ndjson.gz"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [folder.lastPathComponent])
    }

    /// Finding 4: a conversion that fails leaves nothing in the cache, and the next try
    /// converts again.
    func testAFailedConversionIsNeverCached() async throws {
        let folder = try interruptedV1()
        let cache = root.appendingPathComponent("Shared")
        let motion = folder.appendingPathComponent("motion.ndjson.gz")
        let good = try Data(contentsOf: motion)
        try Data("not gzip".utf8).write(to: motion)
        do {
            _ = try await ZipExport.preparedRecording(folder: folder, root: cache)
            XCTFail("a recording whose motion stream cannot be inflated must not be shared")
        } catch {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [], [])
        try good.write(to: motion)
        let prepared = try await ZipExport.preparedRecording(folder: folder, root: cache)
        XCTAssertEqual(try RawSessionReader.readMeta(folder: prepared).version, RawFormat.version)
    }

    /// Finding 5: the cache entry names the raw format version it was converted to.
    func testTheCacheKeyIncludesTheTargetFormatVersion() async throws {
        let folder = try interruptedV1()
        let prepared = try await ZipExport.preparedRecording(folder: folder, root: root.appendingPathComponent("Shared"))
        let entry = prepared.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(entry, ZipExport.cacheKey(of: folder))
        XCTAssertTrue(entry.hasPrefix("v\(RawFormat.version)-"))
        XCTAssertTrue(entry.hasSuffix(ZipExport.revisionKey(of: folder)))
    }

    func testLaunchRemovesStaleStagingFiles() throws {
        let folder = try interruptedV1()
        RecordingStore.removeStaleStagingFiles(in: folder.deletingLastPathComponent())
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["meta.json", "motion.ndjson.gz"])
    }

    func testTheWatchSendsAVersionOnlyToAPhoneThatReadsIt() {
        // A phone build from before raw format 2 advertises nothing: it reads version 1.
        let old = RecordingTransfer.phoneRawVersions(fromContext: ["settings": [:] as [String: Any]])
        XCTAssertEqual(old, [1])
        let new = RecordingTransfer.phoneRawVersions(fromContext: ["rawVersions": [1, 2]])
        XCTAssertEqual(new, [1, 2])
        XCTAssertFalse(RecordingTransfer.mayDeliver(version: 2, toPhoneReading: old))
        XCTAssertTrue(RecordingTransfer.mayDeliver(version: 1, toPhoneReading: old))
        XCTAssertTrue(RecordingTransfer.mayDeliver(version: 2, toPhoneReading: new))
        XCTAssertFalse(RecordingTransfer.mayDeliver(version: nil, toPhoneReading: new))
        // This build advertises what it reads.
        XCTAssertEqual(Set(RecordingTransfer.readableRawVersions), RawFormat.readableVersions)
        XCTAssertEqual(RecordingTransfer.readableRawVersions, [1, 2, 3])
    }

    /// A watch updated before its phone keeps writing version 2 until the phone says it reads 3.
    func testTheWatchRecordsAVersionItsPhoneReads() {
        // A phone build from before raw format 3, and one from before raw format 2.
        XCTAssertEqual(RecordingTransfer.recordingVersion(phoneReads: [1, 2]), 2)
        XCTAssertEqual(RecordingTransfer.recordingVersion(phoneReads: [1]), 2)
        // No application context from the phone yet.
        XCTAssertEqual(
            RecordingTransfer.recordingVersion(phoneReads: RecordingTransfer.phoneRawVersions(fromContext: [:])), 2)
        // A phone that reads version 3, and a later one that reads more.
        XCTAssertEqual(RecordingTransfer.recordingVersion(phoneReads: [1, 2, 3]), 3)
        XCTAssertEqual(RecordingTransfer.recordingVersion(phoneReads: [1, 2, 3, 4]), 3)
        // The phone itself writes the latest version, which it reads.
        XCTAssertEqual(RecordingTransfer.recordingVersion(), RawFormat.version)
        XCTAssertEqual(RawFormat.version, 3)
        // What a watch writes for a phone, that phone takes.
        for phone: Set<Int> in [[1], [1, 2], [1, 2, 3]] where phone.contains(2) {
            let version = RecordingTransfer.recordingVersion(phoneReads: phone)
            XCTAssertTrue(RecordingTransfer.mayDeliver(version: version, toPhoneReading: phone), "\(phone)")
        }
    }

    /// Scoped re-check of #87, finding 1: a recording whose version cannot be read, or is one
    /// the phone does not advertise, stays on the watch.
    func testTheWatchKeepsARecordingWhoseVersionItCannotRead() throws {
        let phone: Set<Int> = [1, 2]
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metaURL = folder.appendingPathComponent(RawFormat.metaFileName)
        // No meta.json at all, then an unreadable one.
        XCTAssertFalse(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: phone))
        try Data("{\"format\":\"madegood-raw\",".utf8).write(to: metaURL)
        XCTAssertFalse(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: phone))
        // A newer version (left by a build that was rolled back) the phone does not read.
        try Data(#"{"format":"madegood-raw","version":3,"sessionId":"x"}"#.utf8).write(to: metaURL)
        XCTAssertEqual(RecordingTransfer.metaVersion(try Data(contentsOf: metaURL)), 3)
        XCTAssertFalse(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: phone))
        try RawFormat.encodeMeta(meta()).write(to: metaURL)
        XCTAssertFalse(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: phone))
        XCTAssertTrue(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: [1, 2, 3]))
        // The versions the phone reads go.
        var v2 = meta()
        v2.version = 2
        try RawFormat.encodeMeta(v2).write(to: metaURL)
        XCTAssertTrue(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: phone))
        try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: 1)).write(to: metaURL)
        XCTAssertTrue(RecordingTransfer.mayDeliver(folder: folder, toPhoneReading: [1]))
    }

    func testThePhoneNeverAcknowledgesAVersionItCannotRead() throws {
        XCTAssertTrue(RecordingTransfer.acknowledgesMeta(try RawFormat.encodeMeta(meta())))
        XCTAssertTrue(
            RecordingTransfer.acknowledgesMeta(
                try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: 1))))
        XCTAssertTrue(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"madegood-raw","version":3}"#.utf8)))
        XCTAssertTrue(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"madegood-raw","version":2}"#.utf8)))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"madegood-raw","version":4}"#.utf8)))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"gpx","version":2}"#.utf8)))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data("garbage".utf8)))
    }
}
