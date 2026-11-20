import Foundation
import WaterKit

/// Where raw recordings live on this device: `Documents/Recordings/<sessionId>/`.
enum RecordingStore {
    static var demoNamespace: UUID? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-demoHistory") || arguments.contains("-demoMoments"),
                let index = arguments.firstIndex(of: "-demoHistoryNamespace"),
                arguments.indices.contains(index + 1)
            {
                return UUID(uuidString: arguments[index + 1])
            }
        #endif
        return nil
    }

    static var root: URL {
        #if DEBUG && os(iOS)
            if let demo = DemoOffWater.storage {
                return demo.appendingPathComponent("Recordings", isDirectory: true)
            }
        #endif
        if let demoNamespace {
            let documents = recordingsRoot.deletingLastPathComponent()
            return documents.appendingPathComponent("DemoHistory", isDirectory: true)
                .appendingPathComponent(demoNamespace.uuidString, isDirectory: true)
        }
        return recordingsRoot
    }

    /// Watch transfers always land in the normal library, even during a demo.
    static var recordingsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    /// Prefix of the staging copies `RecordingTransfer` writes before moving a file into place.
    static let stagingPrefix = ".incoming-"

    /// Deletes staging copies left by a transfer that was interrupted (for example by the app
    /// being stopped). Call at launch, before transfers start. They are never part of a
    /// recording, and one from before raw format 2 may hold device uptime.
    static func removeStaleStagingFiles(in root: URL = recordingsRoot) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(stagingPrefix) {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    static func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.folder)
    }
}
