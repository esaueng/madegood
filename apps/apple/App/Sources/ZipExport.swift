import Foundation
import WaterKit

/// Zips a recording folder for AirDrop/Files using the system's built-in archiver
/// (`NSFileCoordinator` with `.forUploading`).
enum ZipExport {
    enum Failure: Error {
        case noArchive
    }

    /// Where prepared copies of recordings for sharing are kept, by recording, then by target
    /// raw format version and revision (`cacheKey`).
    static var preparedRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharedRecordings", isDirectory: true)
    }

    /// A stable key for the recording's files as they are now (names, sizes, dates).
    static func revisionKey(of folder: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for byte in String(describing: RawSessionReader.revision(of: folder)).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The cache entry name of a prepared copy: the raw format version it was converted to
    /// and the recording's revision, so a newer app never reuses an older conversion.
    static func cacheKey(of folder: URL) -> String {
        "v\(RawFormat.version)-\(revisionKey(of: folder))"
    }

    /// Preparations in flight, by recording: one at a time per recording, so concurrent
    /// shares of it never race on its cache entry.
    private actor Preparations {
        private var running: [String: Task<URL, any Error>] = [:]

        func run(_ name: String, _ work: @escaping @Sendable () throws -> URL) async throws -> URL {
            // Queued behind the last preparation of this recording (it may make the copy this
            // one then finds), with no suspension between reading and replacing the tail.
            let previous = running[name]
            let task = Task.detached(priority: .userInitiated) {
                _ = try? await previous?.value
                return try work()
            }
            running[name] = task
            defer { if running[name] == task { running[name] = nil } }
            return try await task.value
        }
    }
    private static let preparations = Preparations()

    /// Deletes every prepared copy of a recording (all revisions), as when it is deleted.
    static func removePrepared(for folder: URL, root: URL = preparedRoot) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder.lastPathComponent, isDirectory: true))
    }

    /// Deletes prepared copies of recordings that no longer exist, and leftovers of an
    /// interrupted preparation (older than an hour, so never one still running). Call at launch.
    static func prunePrepared(keeping names: Set<String>, root: URL = preparedRoot, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !names.contains(name) {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix(".partial-") {
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                if let modified, now.timeIntervalSince(modified) < 3600 { continue }
            }
            try? fm.removeItem(at: url)
        }
    }

    /// The recording as shared: the current raw format version (a recording from before
    /// version 2 is converted, so no shared file holds a device-uptime reading) and only its
    /// own files (never a staging copy of an interrupted watch transfer or the derived track).
    /// Prepared off the main actor, streamed (`RawFormatConversion`), and kept per revision of
    /// the recording, so sharing it again is instant. Returns the prepared folder.
    static func preparedRecording(
        folder: URL, root: URL = preparedRoot, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let name = folder.lastPathComponent
        return try await preparations.run(root.path + "/" + name) {
            let fm = FileManager.default
            let recordingRoot = root.appendingPathComponent(name, isDirectory: true)
            let prepared = recordingRoot.appendingPathComponent(cacheKey(of: folder), isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: prepared.path) {
                progress(1)
                return prepared
            }
            // Earlier revisions (and format versions) of this recording are stale now.
            try? fm.removeItem(at: recordingRoot)
            let partial = root.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: partial) }
            // A failed conversion throws, so nothing partial is ever moved into the cache.
            try RawFormatConversion.exportCopy(folder: folder, into: partial, progress: progress)
            try fm.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: partial, to: prepared)
            } catch where fm.fileExists(atPath: prepared.path) {
                // Prepared meanwhile for the same revision (by another process): use it.
            }
            return prepared
        }
    }

    /// Shares a recording (`preparedRecording`) as a zip in `ExportFiles.directory`.
    static func zipRecording(
        folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let prepared = try await preparedRecording(folder: folder, progress: progress)
        return try await Task.detached(priority: .userInitiated) { try zip(folder: prepared) }.value
    }

    /// Returns a zip in `ExportFiles.directory` named after the folder. The coordinator's
    /// own archive is deleted when the accessor returns, so it is copied out inside it.
    static func zip(folder: URL, name: String? = nil, in directory: URL = ExportFiles.directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name ?? "madegood-\(folder.lastPathComponent).zip")
        var coordinatorError: NSError?
        var copyError: (any Error)?
        var copied = false

        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) {
            archive in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: archive, to: destination)
                copied = true
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard copied else { throw Failure.noArchive }
        return destination
    }

    /// What Export All Recordings made: the zip, and how many folders could not be included
    /// (not a readable recording).
    struct AllRecordings: Equatable {
        var zip: URL
        var skipped: Int
    }

    /// Settings → Export All Recordings: every recording on this iPhone in one zip, one folder
    /// per recording, each exactly as Share raw recording sends it (`preparedRecording`):
    /// raw format 2, converted from an older version through the streaming converter and the
    /// shared cache, and only the recording's own files (no staging copy of an interrupted
    /// watch transfer, no derived track). So no device-uptime reading leaves the phone. Nil
    /// when there are no recordings. Runs off the main actor; `progress` goes from 0 to 1.
    static func zipAllRecordings(
        root: URL, in directory: URL = ExportFiles.directory, cache: URL = preparedRoot,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AllRecordings? {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent(".all-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent("madegood-recordings", isDirectory: true)
        guard let skipped = try await stageAllRecordings(root: root, into: folder, cache: cache, progress: progress)
        else { return nil }
        let zip = try await Task.detached(priority: .userInitiated) {
            try zip(folder: folder, name: "madegood-recordings.zip", in: directory)
        }.value
        return AllRecordings(zip: zip, skipped: skipped)
    }

    /// Copies the prepared form of every recording folder under `root` into `destination`
    /// (one subfolder each). Returns how many folders were skipped because they are not
    /// readable recordings, or nil when `root` holds no recording folders at all.
    static func stageAllRecordings(
        root: URL, into destination: URL, cache: URL = preparedRoot,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Int? {
        let folders = try await Task.detached(priority: .userInitiated) { () -> [URL] in
            let fm = FileManager.default
            return ((try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
        guard !folders.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var skipped = 0
        progress(0)
        for (index, folder) in folders.enumerated() {
            let share = Double(index) / Double(folders.count)
            let step = 1 / Double(folders.count)
            let prepared: URL
            do {
                prepared = try await preparedRecording(folder: folder, root: cache) { fraction in
                    progress(share + step * fraction)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not a readable recording (no or damaged meta.json, or a stream that cannot
                // be converted): left out, and counted for the message.
                skipped += 1
                continue
            }
            try await Task.detached(priority: .userInitiated) {
                // A clone on APFS: the prepared copy stays in the cache for single shares.
                try FileManager.default.copyItem(
                    at: prepared, to: destination.appendingPathComponent(folder.lastPathComponent, isDirectory: true))
            }.value
        }
        progress(1)
        return skipped
    }
}

/// Files made only to be shared (GPX, zipped recordings) live in their own temporary folder:
/// each is deleted when its share sheet finishes, and the folder is emptied at launch in
/// case the app ended while one was open. A recording library can make a large zip.
enum ExportFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// A destination for a new export file.
    static func url(named name: String, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// Deletes an export file once its share sheet has finished with it. Files outside the
    /// exports folder are never touched.
    static func discard(_ url: URL, in directory: URL = directory) {
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every leftover export file (call at launch).
    static func removeAll(in directory: URL = directory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
