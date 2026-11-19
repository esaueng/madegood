import Foundation
import WaterKit

/// Zips a recording folder for AirDrop/Files using the system's built-in archiver
/// (`NSFileCoordinator` with `.forUploading`).
enum ZipExport {
    enum Failure: Error {
        case noArchive
    }

    /// Returns a zip in the temporary directory named after the folder. The coordinator's
    /// own archive is deleted when the accessor returns, so it is copied out inside it.
    /// Shares a recording in the current raw format: one recorded before version 2 is
    /// converted first (`RawFormatConversion`), so no shared file holds a device-uptime
    /// reading. Returns the zip in the temporary directory.
    static func zipRecording(folder: URL) throws -> URL {
        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-v\(RawFormat.version)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: converted.deletingLastPathComponent()) }
        let source = try RawFormatConversion.convertToCurrent(folder: folder, into: converted) ? converted : folder
        return try zip(folder: source)
    }

    static func zip(folder: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("madegood-\(folder.lastPathComponent).zip")
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
}
