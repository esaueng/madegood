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

    func testZipOfAllRecordingsLandsInTheExportsFolderAndIsDiscardedAfterSharing() async throws {
        let library = root.appendingPathComponent("Recordings", isDirectory: true)
        let recording = library.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: recording.appendingPathComponent("meta.json"))

        let made = try await ZipExport.zipAllRecordings(root: library, in: exports)
        let zip = try XCTUnwrap(made)
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
        let zip = try await ZipExport.zipAllRecordings(root: library, in: exports)
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
