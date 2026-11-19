import Foundation

/// Zips a recording folder for AirDrop/Files using the system's built-in archiver
/// (`NSFileCoordinator` with `.forUploading`).
enum ZipExport {
    enum Failure: Error {
        case noArchive
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

    /// Settings → Export All Recordings: every recording folder on this iPhone (raw sensor
    /// files and the analyzed track) in one zip, laid out as in the Files app. Nil when there
    /// are no recordings. Runs the archiver off the main actor; a large library takes a while.
    static func zipAllRecordings(root: URL, in directory: URL = ExportFiles.directory) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            guard folders.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            else { return nil }
            return try zip(folder: root, name: "madegood-recordings.zip", in: directory)
        }.value
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
