import Foundation

/// Zips a recording folder for AirDrop/Files using the system's built-in archiver
/// (`NSFileCoordinator` with `.forUploading`).
enum ZipExport {
    enum Failure: Error {
        case noArchive
    }

    /// Returns a zip in the temporary directory named after the folder. The coordinator's
    /// own archive is deleted when the accessor returns, so it is copied out inside it.
    static func zip(folder: URL, name: String? = nil) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(name ?? "madegood-\(folder.lastPathComponent).zip")
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
    static func zipAllRecordings(root: URL) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            guard folders.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            else { return nil }
            return try zip(folder: root, name: "madegood-recordings.zip")
        }.value
    }
}
