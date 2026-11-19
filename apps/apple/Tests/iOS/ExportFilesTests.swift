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

    // Review of #91.

    /// A plain v2 recording in `library`.
    private func v2Recording(in library: URL, named name: String = UUID().uuidString.lowercased()) throws -> URL {
        let folder = library.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RawFormat.encodeMeta(meta()).write(to: folder.appendingPathComponent("meta.json"))
        try Data(#"{"ts":946684801,"type":"start"}"#.utf8 + [0x0A]).write(to: folder.appendingPathComponent("events.ndjson"))
        return folder
    }

    /// Findings 1 and 4: a stream name that is a directory (holding an old clock file), or a
    /// stream both plain and gzipped, makes a recording unreadable: skipped and counted,
    /// and nothing from it is exported.
    func testOddlyLaidOutRecordingsAreSkippedNotCopied() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        let good = try v2Recording(in: library)
        let withDirectory = try v1Recording(in: library)
        let dir = withDirectory.appendingPathComponent("gps.ndjson", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Gzip.compress(RawFormat.line(RawFormat.V1.ClockAnchor(unix: start, uptime: 5_000)))
            .write(to: dir.appendingPathComponent("clock.ndjson.gz"))
        let both = try v2Recording(in: library)
        try Data().write(to: both.appendingPathComponent("hr.ndjson"))
        try Gzip.compress(Data()).write(to: both.appendingPathComponent("hr.ndjson.gz"))

        let staged = root.appendingPathComponent("Staged", isDirectory: true)
        let skipped = try await ZipExport.stageAllRecordings(root: library, into: staged, cache: cache)
        XCTAssertEqual(skipped, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.path), [good.lastPathComponent])
        XCTAssertFalse(try allText(in: staged).contains("uptime"))
        // A single share refuses them too.
        for folder in [withDirectory, both] {
            do {
                _ = try await ZipExport.preparedRecording(folder: folder, root: cache)
                XCTFail("\(folder.lastPathComponent) must not be shared")
            } catch {
                XCTAssertTrue(RawFormatConversion.isInvalidRecording(error), "\(error)")
            }
        }
    }

    /// Finding 2: a storage failure is not an unreadable recording: the export fails and
    /// leaves nothing behind.
    func testAStorageFailureFailsTheWholeExport() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        _ = try v2Recording(in: library)
        _ = try v1Recording(in: library)
        // The cache cannot be created: a file is where its folder should be.
        let blocked = root.appendingPathComponent("BlockedCache")
        try Data("x".utf8).write(to: blocked)
        do {
            _ = try await ZipExport.zipAllRecordings(root: library, in: exports, cache: blocked)
            XCTFail("an export that could not write its copies must fail, not skip them")
        } catch {
            XCTAssertFalse(RawFormatConversion.isInvalidRecording(error), "\(error)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [], [])
    }

    /// Finding 3: while the export copies a recording's prepared copy, a share of a newer
    /// revision waits instead of deleting it.
    func testANewerRevisionWaitsWhileAPreparedCopyIsInUse() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        let folder = try v2Recording(in: library)
        let newer = LockedValues()
        let cacheURL = cache
        let stillThere = try await ZipExport.withPreparedRecording(folder: folder, root: cacheURL) { prepared -> Bool in
            // The recording changes, and a single share of the new revision starts now.
            try Data("{}\n".utf8).write(to: folder.appendingPathComponent("hr.ndjson"))
            Task.detached {
                _ = try? await ZipExport.preparedRecording(folder: folder, root: cacheURL)
                newer.append(1)
            }
            Thread.sleep(forTimeInterval: 0.3)
            return FileManager.default.fileExists(atPath: prepared.appendingPathComponent("meta.json").path)
                && newer.values.isEmpty
        }
        XCTAssertTrue(stillThere, "the copy in use was deleted, or the newer share did not wait")
        // Afterwards the newer revision is prepared as usual.
        let current = try await ZipExport.preparedRecording(folder: folder, root: cache)
        XCTAssertEqual(current.deletingLastPathComponent().lastPathComponent, ZipExport.cacheKey(of: folder))
    }

    /// Finding 5: cancelling the export stops it and leaves no zip or staging copy.
    func testCancellingTheExportLeavesNothing() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        for _ in 0..<3 { _ = try v1Recording(in: library) }
        let handle = LockedTask()
        let (exportsURL, cacheURL) = (exports, cache)
        let task = Task {
            try await ZipExport.zipAllRecordings(root: library, in: exportsURL, cache: cacheURL) { _ in handle.cancel() }
        }
        handle.set(task)
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [], [])
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

/// The export task, cancelled from its own progress callback.
private final class LockedTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ZipExport.AllRecordings?, any Error>?
    private var cancelRequested = false
    func set(_ task: Task<ZipExport.AllRecordings?, any Error>) {
        lock.withLock {
            self.task = task
            if cancelRequested { task.cancel() }
        }
    }
    func cancel() {
        lock.withLock {
            cancelRequested = true
            task?.cancel()
        }
    }
}
