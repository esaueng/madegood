import Foundation

/// Large recording files go from the watch to the phone in parts of `partSize`, each its
/// own file transfer. WatchConnectivity sends one file at a time, slowly (a 35 MB motion
/// stream took about 17 minutes with the app open), and starts a cancelled or failed
/// transfer over from the beginning. In parts, an interruption costs one part, the parts
/// already received stay on the phone, and the phone says which it holds, so the watch
/// sends only the rest.
///
/// - Watch: each part is a slice of the recording's file, written to `.parts/<file>.<index>`
///   in the recording folder just before it is queued.
/// - Phone: received parts wait in `.parts/<file>/<index>`. When all are there, they are
///   joined into a staged file, checked against the total size, and put in place like a
///   file sent whole; then the parts are removed.
///
/// `.parts` is never a recording file (`RecordingStore.isRecordingFileName`), so listing,
/// exporting, the phone's acknowledgements and the watch's delete decision ignore it. The
/// recording's own files are never changed; parts are copies.
enum TransferParts {
    /// The size of every part but the last. Files up to this size go whole.
    static let partSize: Int64 = 1 << 20
    /// The hidden folder in a recording that holds parts.
    static let folderName = ".parts"
    /// The largest part size the phone accepts, so a malformed transfer can't ask it to
    /// hold or join something absurd.
    static let maximumPartSize: Int64 = 16 << 20

    struct Part: Hashable, Sendable {
        var file: String
        var index: Int
        var count: Int
        var total: Int64
        var partSize: Int64

        var offset: Int64 { Int64(index) * partSize }
        var length: Int64 { min(partSize, total - offset) }
    }

    /// The parts of a file of `size` bytes; empty when it goes whole.
    static func plan(file: String, size: Int64, partSize: Int64 = partSize) -> [Part] {
        guard partSize > 0, size > partSize else { return [] }
        let count = Int((size + partSize - 1) / partSize)
        return (0..<count).map { Part(file: file, index: $0, count: count, total: size, partSize: partSize) }
    }

    // MARK: Transfer metadata

    private enum Key {
        static let part = "part"
        static let parts = "parts"
        static let total = "total"
        static let partSize = "partSize"
    }

    /// The metadata a part adds to its transfer's.
    static func metadata(for part: Part) -> [String: Any] {
        [Key.part: part.index, Key.parts: part.count, Key.total: part.total, Key.partSize: part.partSize]
    }

    /// The part a transfer of `file` carries, from its metadata; nil for a file sent whole.
    /// Throws when the metadata names a part that can't be right.
    static func part(file: String, metadata: [String: Any]?) throws -> Part? {
        guard let metadata, metadata[Key.part] != nil else { return nil }
        guard let index = (metadata[Key.part] as? NSNumber)?.intValue,
            let count = (metadata[Key.parts] as? NSNumber)?.intValue,
            let total = (metadata[Key.total] as? NSNumber)?.int64Value,
            let partSize = (metadata[Key.partSize] as? NSNumber)?.int64Value,
            partSize > 0, partSize <= maximumPartSize, total > partSize,
            count == Int((total + partSize - 1) / partSize), (0..<count).contains(index)
        else { throw PartError.invalidMetadata }
        return Part(file: file, index: index, count: count, total: total, partSize: partSize)
    }

    enum PartError: Error, CustomStringConvertible {
        case invalidMetadata
        case wrongSize(expected: Int64, actual: Int64?)
        case joinedWrongSize(expected: Int64, actual: Int64)

        var description: String {
            switch self {
            case .invalidMetadata: "the part's metadata is invalid"
            case .wrongSize(let expected, let actual):
                "the part is \(actual.map(String.init) ?? "?") bytes, expected \(expected)"
            case .joinedWrongSize(let expected, let actual):
                "the joined file is \(actual) bytes, expected \(expected)"
            }
        }
    }

    // MARK: Watch

    /// Where the watch writes a part before sending it.
    static func sliceURL(_ part: Part, in recording: URL) -> URL {
        recording.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(part.file).\(part.index)")
    }

    /// Writes the part's slice of the recording's file (or reuses one already written at
    /// the right size) and returns where it is.
    static func slice(_ part: Part, in recording: URL) throws -> URL {
        let fm = FileManager.default
        let url = sliceURL(part, in: recording)
        if size(of: url) == part.length { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: recording.appendingPathComponent(part.file))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(part.offset))
        let data = try handle.read(upToCount: Int(part.length)) ?? Data()
        guard Int64(data.count) == part.length else {
            throw PartError.wrongSize(expected: part.length, actual: Int64(data.count))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Phone

    /// Where the phone keeps the parts of `file` received so far.
    static func receivedFolder(file: String, in recording: URL) -> URL {
        recording.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(file, isDirectory: true)
    }

    enum Stored: Equatable {
        case stored, alreadyHad, replaced
    }

    /// Keeps a received part (moving `incoming` away; WatchConnectivity deletes it after the
    /// callback). One already held at the right size stays; a wrong size is refused.
    static func store(_ incoming: URL, as part: Part, in recording: URL) throws -> Stored {
        guard size(of: incoming) == part.length else {
            throw PartError.wrongSize(expected: part.length, actual: size(of: incoming))
        }
        let fm = FileManager.default
        let folder = receivedFolder(file: part.file, in: recording)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(String(part.index))
        if fm.fileExists(atPath: destination.path) {
            if size(of: destination) == part.length { return .alreadyHad }
            _ = try fm.replaceItemAt(destination, withItemAt: incoming)
            return .replaced
        }
        try fm.moveItem(at: incoming, to: destination)
        return .stored
    }

    /// The parts held for each file still arriving, by index.
    static func held(in recording: URL) -> [String: [Int]] {
        let fm = FileManager.default
        let root = recording.appendingPathComponent(folderName, isDirectory: true)
        var held: [String: [Int]] = [:]
        for file in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let indices = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(file).path)) ?? [])
                .compactMap(Int.init).sorted()
            if !indices.isEmpty { held[file] = indices }
        }
        return held
    }

    /// Joins the parts of `part.file` into a staged file in the recording folder once all of
    /// them are held, checking every part's size and the total; nil while any is missing.
    /// The caller puts the staged file in place and removes the parts.
    static func join(_ part: Part, in recording: URL, stagingPrefix: String) throws -> URL? {
        let fm = FileManager.default
        let folder = receivedFolder(file: part.file, in: recording)
        let parts = (0..<part.count).map {
            Part(file: part.file, index: $0, count: part.count, total: part.total, partSize: part.partSize)
        }
        for each in parts where size(of: folder.appendingPathComponent(String(each.index))) != each.length {
            return nil
        }
        let staged = recording.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)-\(part.file)")
        guard fm.createFile(atPath: staged.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            for each in parts {
                try output.write(contentsOf: try Data(contentsOf: folder.appendingPathComponent(String(each.index))))
            }
            try output.synchronize()
            let joined = size(of: staged) ?? -1
            guard joined == part.total else { throw PartError.joinedWrongSize(expected: part.total, actual: joined) }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Removes the parts of `file`, once it is in place.
    static func removeParts(file: String, in recording: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: receivedFolder(file: file, in: recording))
        let root = recording.appendingPathComponent(folderName, isDirectory: true)
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? fm.removeItem(at: root)
        }
    }

    static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }
}
