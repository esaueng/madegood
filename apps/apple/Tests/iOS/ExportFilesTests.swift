import WaterKit
import XCTest

@testable import MadeGood

/// Export files are deleted after sharing and at launch (review of #79, finding 5).
final class ExportFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private var cache: URL { root.appendingPathComponent("Shared", isDirectory: true) }
    private let start = 946_684_800.0

    private func meta() -> RawFormat.Meta {
        RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: start, endedAt: start + 10,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
    }

    /// A version 1 recording with device uptime in its clocks, plus what does not belong in an
    /// export: an interrupted transfer's staging copy and the derived track.
    private func v1Recording(in library: URL) throws -> URL {
        let folder = library.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: 5_000))
            .write(to: folder.appendingPathComponent("meta.json"))
        let motion = try RawFormat.line(
            RawFormat.MotionLine(
                ts: 5_000.5, userAcceleration: .zero, gravity: .zero, rotationRate: .zero, attitude: .identity))
        try Gzip.compress(motion).write(to: folder.appendingPathComponent("motion.ndjson.gz"))
        try Gzip.compress(RawFormat.line(RawFormat.V1.ClockAnchor(unix: start + 1, uptime: 5_001)))
            .write(to: folder.appendingPathComponent("clock.ndjson.gz"))
        try Gzip.compress(RawFormat.line(RawFormat.V1.ClockAnchor(unix: start, uptime: 5_000)))
            .write(to: folder.appendingPathComponent("\(RecordingStore.stagingPrefix)\(UUID().uuidString)-clock.ndjson.gz"))
        try Data("derived".utf8).write(to: folder.appendingPathComponent(RecordingStore.trackFileName))
        return folder
    }

    private func allText(in folder: URL) throws -> String {
        var text = ""
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let data = try Data(contentsOf: url)
            text += String(decoding: Gzip.isGzipped(data) ? try Gzip.decompress(data) : data, as: UTF8.self)
        }
        return text
    }

    /// Export All Recordings sends each recording as Share raw recording does: raw format 2
    /// (an older one converted through the streaming converter and its cache), only its own
    /// files, and no device-uptime reading.
    func testExportAllRecordingsConvertsAndFiltersEachRecording() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        let old = try v1Recording(in: library)
        let current = library.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try RawFormat.encodeMeta(meta()).write(to: current.appendingPathComponent("meta.json"))
        try Data(#"{"ts":946684801,"type":"start"}"#.utf8 + [0x0A]).write(to: current.appendingPathComponent("events.ndjson"))
        try Data("derived".utf8).write(to: current.appendingPathComponent(RecordingStore.trackFileName))
        // A folder that is not a readable recording is left out and counted.
        let junk = library.appendingPathComponent("not-a-recording", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: junk.appendingPathComponent("meta.json"))

        let staged = root.appendingPathComponent("Staged", isDirectory: true)
        let reported = LockedValues()
        let skipped = try await ZipExport.stageAllRecordings(root: library, into: staged, cache: cache) {
            reported.append($0)
        }
        XCTAssertEqual(skipped, 1)
        let fm = FileManager.default
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: staged.path).sorted(),
            [current.lastPathComponent, old.lastPathComponent].sorted())
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: staged.appendingPathComponent(old.lastPathComponent).path).sorted(),
            ["clock.ndjson.gz", "meta.json", "motion.ndjson.gz"])
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: staged.appendingPathComponent(current.lastPathComponent).path).sorted(),
            ["events.ndjson", "meta.json"])
        XCTAssertFalse(try allText(in: staged).contains("uptime"), "no device-uptime reading leaves the phone")
        for name in [old.lastPathComponent, current.lastPathComponent] {
            XCTAssertEqual(try RawSessionReader.readMeta(folder: staged.appendingPathComponent(name)).version, RawFormat.version)
        }
        let values = reported.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress only goes forward")

        // The converted copy is the shared cache entry, reused by a single share.
        let single = try await ZipExport.preparedRecording(folder: old, root: cache)
        XCTAssertEqual(single.deletingLastPathComponent().lastPathComponent, ZipExport.cacheKey(of: old))
        // The library itself is untouched.
        XCTAssertTrue(exists(old.appendingPathComponent(RecordingStore.trackFileName)))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: old.path).contains { $0.hasPrefix(RecordingStore.stagingPrefix) })
    }

    func testZipOfAllRecordingsLandsInTheExportsFolderAndIsDiscardedAfterSharing() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        let recording = library.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try RawFormat.encodeMeta(meta()).write(to: recording.appendingPathComponent("meta.json"))

        let made = try await ZipExport.zipAllRecordings(root: library, in: exports, cache: cache)
        let zip = try XCTUnwrap(made?.zip)
        XCTAssertEqual(made?.skipped, 0)
        // Only the zip is left in the exports folder: the staging copy is gone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exports.path), ["madegood-recordings.zip"])
        XCTAssertEqual(zip.deletingLastPathComponent().standardizedFileURL, exports.standardizedFileURL)
        XCTAssertEqual(zip.lastPathComponent, "madegood-recordings.zip")
        XCTAssertTrue(exists(zip))

        // What the share sheet's completion handler does.
        ExportFiles.discard(zip, in: exports)
        XCTAssertFalse(exists(zip))
        XCTAssertTrue(exists(recording), "the recordings themselves are never touched")
    }

    func testNoZipForAnEmptyLibrary() async throws {
        let library = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let zip = try await ZipExport.zipAllRecordings(root: library, in: exports, cache: cache)
        XCTAssertNil(zip)
    }

    func testDiscardLeavesFilesOutsideTheExportsFolder() throws {
        let outside = root.appendingPathComponent("keep.gpx")
        try Data("x".utf8).write(to: outside)
        ExportFiles.discard(outside, in: exports)
        XCTAssertTrue(exists(outside))
    }

    func testLaunchCleanupRemovesLeftoverExports() throws {
        let gpx = try ExportFiles.url(named: "sailing-1.gpx", in: exports)
        let zip = try ExportFiles.url(named: "madegood-recordings.zip", in: exports)
        try Data("x".utf8).write(to: gpx)
        try Data("x".utf8).write(to: zip)

        ExportFiles.removeAll(in: exports)
        XCTAssertFalse(exists(gpx))
        XCTAssertFalse(exists(zip))
        // A new export after cleanup recreates the folder.
        let next = try ExportFiles.url(named: "next.gpx", in: exports)
        XCTAssertNoThrow(try Data("x".utf8).write(to: next))
    }

    func testDefaultFolderIsInsideTheTemporaryDirectory() {
        XCTAssertEqual(
            ExportFiles.directory.deletingLastPathComponent().standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL)
    }
}

/// Progress values reported from another task.
private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
