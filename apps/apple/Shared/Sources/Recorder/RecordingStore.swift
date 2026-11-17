import Foundation
import WaterKit

/// Where raw recordings live on this device: `Documents/Recordings/<sessionId>/`.
enum RecordingStore {
    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func folder(for sessionId: UUID) -> URL {
        root.appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
    }

    /// File names a recording folder may contain (used to validate transferred files).
    static func isRecordingFileName(_ name: String) -> Bool {
        if name == RawFormat.metaFileName { return true }
        return RawFormat.Stream.allCases.contains { name == $0.fileName || name == $0.gzippedFileName }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        var id: URL { folder }
        var folder: URL
        var meta: RawFormat.Meta?
        var bytes: Int64
        var files: [String]

        var startedAt: Date? { meta.map { Date(timeIntervalSince1970: $0.startedAt) } }
        var duration: TimeInterval? { meta.flatMap { meta in meta.endedAt.map { $0 - meta.startedAt } } }
    }

    /// All recordings, newest first.
    static func list() -> [Entry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Entry? in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isRecordingFileName).sorted()
            let bytes = files.reduce(Int64(0)) { total, name in
                let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            let meta = try? RawSessionReader.readMeta(folder: folder)
            return Entry(folder: folder, meta: meta, bytes: bytes, files: files)
        }
        .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    static func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.folder)
    }
}
