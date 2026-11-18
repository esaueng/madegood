import Foundation
import WaterKit

/// Where raw recordings live on this device: `Documents/Recordings/<sessionId>/`.
enum RecordingStore {
    static var demoNamespace: UUID? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-demoHistory"),
                let index = arguments.firstIndex(of: "-demoHistoryNamespace"),
                arguments.indices.contains(index + 1)
            {
                return UUID(uuidString: arguments[index + 1])
            }
        #endif
        return nil
    }

    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let demoNamespace {
            return documents.appendingPathComponent("DemoHistory", isDirectory: true)
                .appendingPathComponent(demoNamespace.uuidString, isDirectory: true)
        }
        return documents.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// The track v1 file the phone writes next to a finished raw recording.
    static let trackFileName = "track.json.gz"

    static func folder(for sessionId: UUID) -> URL {
        root.appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
    }

    /// File names a recording folder may contain (used to validate transferred files).
    static func isRecordingFileName(_ name: String) -> Bool {
        RawSessionReader.isRecordingFileName(name)
    }

    struct Entry: Identifiable, Hashable, Sendable {
        var id: URL { folder }
        var folder: URL
        var meta: RawFormat.Meta?
        var revision: [RawSessionReader.FileRevision]

        var startedAt: Date? { meta.map { Date(timeIntervalSince1970: $0.startedAt) } }
        var duration: TimeInterval? { meta.flatMap { meta in meta.endedAt.map { $0 - meta.startedAt } } }
    }

    /// All recordings, newest first.
    static func list() -> [Entry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Entry? in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            let revision = RawSessionReader.revision(of: folder)
            let meta = try? RawSessionReader.readMeta(folder: folder)
            return Entry(folder: folder, meta: meta, revision: revision)
        }
        .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    static func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.folder)
    }
}
