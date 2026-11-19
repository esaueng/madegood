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
        XCTAssertTrue(RecordingTransfer.mayDeliver(version: nil, toPhoneReading: old))
        // This build advertises what it reads.
        XCTAssertEqual(Set(RecordingTransfer.readableRawVersions), RawFormat.readableVersions)
    }

    func testThePhoneNeverAcknowledgesAVersionItCannotRead() throws {
        XCTAssertTrue(RecordingTransfer.acknowledgesMeta(try RawFormat.encodeMeta(meta())))
        XCTAssertTrue(
            RecordingTransfer.acknowledgesMeta(
                try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: 1))))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"madegood-raw","version":3}"#.utf8)))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data(#"{"format":"gpx","version":2}"#.utf8)))
        XCTAssertFalse(RecordingTransfer.acknowledgesMeta(Data("garbage".utf8)))
    }
}
