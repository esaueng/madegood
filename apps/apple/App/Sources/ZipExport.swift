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

    /// The version of how a prepared copy is made. Bump it whenever the preparation changes
    /// what may be in a copy, so no copy made by an older build is ever reused. 2: only
    /// regular files, and no stream both plain and gzipped (review of #91).
    static let prepareSchema = 2

    /// The start of every current cache entry name; entries without it are from an older
    /// build and are deleted at launch.
    static var cacheKeyPrefix: String { "v\(RawFormat.version)-p\(prepareSchema)-" }

    /// The cache entry name of a prepared copy: the raw format version it was converted to,
    /// the preparation schema and the recording's revision, so a newer app never reuses an
    /// older conversion.
    static func cacheKey(of folder: URL) -> String {
        cacheKeyPrefix + revisionKey(of: folder)
    }

    /// Work on a recording's cache entry, by recording: one at a time per recording, so
    /// concurrent shares never race on it, and a preparation of a newer revision (which
    /// deletes the older ones) waits until whoever is reading the older copy has finished.
    private actor Preparations {
        private var tails: [String: Task<Void, Never>] = [:]

        func run<T: Sendable>(_ name: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
            // Queued behind the last work on this recording, with no suspension between
            // reading and replacing the tail.
            let previous = tails[name]
            let task = Task.detached(priority: .userInitiated) { () throws -> T in
                await previous?.value
                // Cancelled while waiting for the turn: give it up without preparing.
                try Task.checkCancellation()
                return try work()
            }
            let tail = Task.detached { _ = try? await task.value }
            tails[name] = tail
            defer { if tails[name] == tail { tails[name] = nil } }
            // The work is detached (it holds the turn); a cancelled caller cancels it, and the
            // conversion stops between files and chunks. The turn ends when the work does.
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
    private static let preparations = Preparations()

    /// Deletes every prepared copy of a recording (all revisions), as when it is deleted.
    static func removePrepared(for folder: URL, root: URL = preparedRoot) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder.lastPathComponent, isDirectory: true))
    }

    /// Deletes prepared copies of recordings that no longer exist, copies made by an older
    /// build (`cacheKeyPrefix`), and leftovers of an interrupted preparation (older than an
    /// hour, so never one still running). Call at launch.
    static func prunePrepared(keeping names: Set<String>, root: URL = preparedRoot, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            if names.contains(name) {
                for entry in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where !entry.hasPrefix(cacheKeyPrefix) {
                    try? fm.removeItem(at: url.appendingPathComponent(entry))
                }
                continue
            }
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
        try await withPreparedRecording(folder: folder, root: root, progress: progress) { $0 }
    }

    /// Runs `body` on the prepared copy (`preparedRecording`) while holding the recording's
    /// turn, so no preparation of a newer revision deletes the copy while `body` reads it.
    /// `body` runs off the main actor.
    static func withPreparedRecording<T: Sendable>(
        folder: URL, root: URL = preparedRoot, progress: @escaping @Sendable (Double) -> Void = { _ in },
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let name = folder.lastPathComponent
        return try await preparations.run(root.path + "/" + name) {
            try body(prepare(folder: folder, name: name, root: root, progress: progress))
        }
    }

    private static func prepare(
        folder: URL, name: String, root: URL, progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let recordingRoot = root.appendingPathComponent(name, isDirectory: true)
        let prepared = recordingRoot.appendingPathComponent(cacheKey(of: folder), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: prepared.path) {
            // Checked again before it is used: only the recording's own regular files, laid
            // out as the reader accepts. Anything else is made again.
            if (try? isValidPreparedCopy(prepared)) == true {
                progress(1)
                return prepared
            }
            try fm.removeItem(at: prepared)
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

    /// Whether a prepared copy holds only the recording's own regular files, with no stream
    /// both plain and gzipped (`RawFormatConversion.recordingFiles`).
    static func isValidPreparedCopy(_ prepared: URL) throws -> Bool {
        let all = try FileManager.default.contentsOfDirectory(atPath: prepared.path)
        do {
            return try RawFormatConversion.recordingFiles(in: prepared).count == all.count
        } catch where RawFormatConversion.isInvalidRecording(error) {
            return false
        }
    }

    /// Shares a recording (`preparedRecording`) as a zip in `ExportFiles.directory`.
    static func zipRecording(
        folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        // Zipped while holding the recording's turn, so a newer revision cannot delete it mid-zip.
        try await withPreparedRecording(folder: folder, progress: progress) { try zip(folder: $0) }
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
    /// A storage failure (no space, a write error) fails the whole export, and cancelling
    /// the calling task stops it; either way nothing is left in `directory`.
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
        try Task.checkCancellation()
        // A name of its own: an earlier export's zip may still be open in a share sheet, and
        // a failure here must delete only what this attempt made.
        let name = "madegood-recordings-\(UUID().uuidString.prefix(8).lowercased()).zip"
        let archive: URL
        do {
            archive = try await Task.detached(priority: .userInitiated) {
                try zip(folder: folder, name: name, in: directory)
            }.value
        } catch {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
            throw error
        }
        if Task.isCancelled {
            try? fm.removeItem(at: archive)
            throw CancellationError()
        }
        return AllRecordings(zip: archive, skipped: skipped)
    }

    /// Copies the prepared form of every recording folder under `root` into `destination`
    /// (one subfolder each). Returns how many folders were skipped because they are not
    /// readable recordings, or nil when `root` holds no recording folders at all. Throws on
    /// a storage failure or cancellation.
    static func stageAllRecordings(
        root: URL, into destination: URL, cache: URL = preparedRoot,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Int? {
        let folders = try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
            let fm = FileManager.default
            // No library folder yet: no recordings. Any error listing it, or reading what is
            // in it, fails the export rather than leaving recordings out unnoticed.
            guard fm.fileExists(atPath: root.path) else { return [] }
            return try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
        guard !folders.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var skipped = 0
        progress(0)
        for (index, folder) in folders.enumerated() {
            try Task.checkCancellation()
            let share = Double(index) / Double(folders.count)
            let step = 1 / Double(folders.count)
            let target = destination.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            do {
                // Copied while holding the recording's turn, so a share of a newer revision
                // cannot delete the prepared copy before it is copied. A clone on APFS; the
                // prepared copy stays in the cache for single shares.
                try await withPreparedRecording(folder: folder, root: cache, progress: { fraction in
                    progress(share + step * fraction)
                }) { prepared in
                    try FileManager.default.copyItem(at: prepared, to: target)
                }
            } catch where RawFormatConversion.isInvalidRecording(error) {
                // Not a readable recording (meta.json, its files, or a stream that cannot be
                // converted): left out, and counted for the message. Anything else (no space,
                // a write error) fails the export.
                skipped += 1
            }
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
