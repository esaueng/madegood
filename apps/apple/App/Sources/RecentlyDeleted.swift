import Foundation
import WaterKit

/// Deleted recordings, kept for `retention` so a delete can be undone, then removed for
/// good. Each one waits in its own folder: `<directory>/<UUID>/info.json` (when and from
/// where it was deleted) beside `recording/`, the recording folder moved there whole.
/// Two deletes of the same session (the watch sent it again) are kept apart.
///
/// It lives in Application Support, not Documents, so the Files app (which shows this
/// app's Documents) never lists deleted sessions.
struct RecentlyDeleted: Sendable {
    /// How long a deleted session can be recovered.
    static let retentionDays = 30
    static let retention = TimeInterval(retentionDays * 24 * 60 * 60)

    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { container.lastPathComponent }
        /// The folder holding `info.json` and `recording/`.
        var container: URL
        /// The recording folder's name in History: the lowercase session ID.
        var folderName: String
        var deletedAt: Date
        var meta: RawFormat.Meta?

        var recording: URL { container.appendingPathComponent(RecentlyDeleted.recordingName, isDirectory: true) }
        var startedAt: Date? { meta.map { Date(timeIntervalSince1970: $0.startedAt) } }
        var expiresAt: Date { deletedAt.addingTimeInterval(RecentlyDeleted.retention) }

        /// Whole days until it is removed, rounded up: "30" just after deleting, "1" on its last day.
        func daysLeft(now: Date) -> Int {
            max(1, Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.up)))
        }
    }

    enum RestoreError: Error, Equatable {
        /// History already has a recording in that folder (the watch sent it again).
        case alreadyInHistory
    }

    private struct Info: Codable {
        var version: Int
        var folder: String
        /// Seconds since 1970.
        var deletedAt: Double
    }

    static let infoName = "info.json"
    static let recordingName = "recording"

    let directory: URL

    /// The app's store, separate for each demo library like the trims and details.
    static var shared: RecentlyDeleted {
        let support =
            DemoOffWater.storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("RecentlyDeleted", isDirectory: true)
        if let namespace = RecordingStore.demoNamespace {
            return RecentlyDeleted(directory: directory.appendingPathComponent(namespace.uuidString, isDirectory: true))
        }
        return RecentlyDeleted(directory: directory)
    }

    /// The deleted recordings, most recently deleted first. Folders this build can't read
    /// (a newer app wrote them) are left alone and not listed.
    func list() -> [Entry] {
        containers().compactMap { container in
            guard let info = Self.info(in: container), info.version == 1,
                FileManager.default.fileExists(atPath: container.appendingPathComponent(Self.recordingName).path)
            else { return nil }
            let recording = container.appendingPathComponent(Self.recordingName, isDirectory: true)
            return Entry(
                container: container, folderName: info.folder,
                deletedAt: Date(timeIntervalSince1970: info.deletedAt),
                meta: try? RawSessionReader.readMeta(folder: recording))
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Moves a recording folder in. The info file is written first, so a recording is never
    /// here without one; a stop in between leaves an empty folder that `removeAbandoned` clears.
    @discardableResult
    func moveIn(_ folder: URL, now: Date = .now) throws -> Entry {
        let fm = FileManager.default
        let container = directory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            let info = Info(version: 1, folder: folder.lastPathComponent, deletedAt: now.timeIntervalSince1970)
            try JSONEncoder().encode(info).write(to: container.appendingPathComponent(Self.infoName), options: .atomic)
            try fm.moveItem(at: folder, to: container.appendingPathComponent(Self.recordingName, isDirectory: true))
        } catch {
            try? fm.removeItem(at: container)
            throw error
        }
        return Entry(
            container: container, folderName: folder.lastPathComponent, deletedAt: now,
            meta: try? RawSessionReader.readMeta(folder: container.appendingPathComponent(Self.recordingName)))
    }

    /// Moves a recording back into `root` under its old folder name, unless something is
    /// already there.
    @discardableResult
    func restore(_ entry: Entry, to root: URL) throws -> URL {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(entry.folderName, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw RestoreError.alreadyInHistory }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.moveItem(at: entry.recording, to: destination)
        try? fm.removeItem(at: entry.container)
        return destination
    }

    /// Removes a deleted recording for good.
    func remove(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.container)
    }

    /// The ones whose time is up.
    func expired(now: Date = .now) -> [Entry] {
        list().filter { $0.expiresAt <= now }
    }

    /// Clears folders a stop left without a recording (between writing the info file and
    /// the move, or after a restore's move). Folders a newer app wrote are kept.
    func removeAbandoned() {
        let fm = FileManager.default
        for container in containers() {
            let hasRecording = fm.fileExists(atPath: container.appendingPathComponent(Self.recordingName).path)
            let hasInfo = fm.fileExists(atPath: container.appendingPathComponent(Self.infoName).path)
            guard !hasRecording, !hasInfo || Self.info(in: container)?.version == 1 else { continue }
            try? fm.removeItem(at: container)
        }
    }

    private func containers() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { url in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func info(in container: URL) -> Info? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent(infoName)) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }
}
