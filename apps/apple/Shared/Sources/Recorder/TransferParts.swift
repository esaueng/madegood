import Foundation

/// Large recording files go from the watch to the phone in parts of `partSize`, each its
/// own file transfer. WatchConnectivity sends one file at a time, slowly (a 35 MB motion
/// stream took about 17 minutes with the app open), and starts a cancelled or failed
/// transfer over from the beginning. In parts, an interruption costs one part, the parts
/// already received stay on the phone, and the phone says which it holds, so the watch
/// sends only the rest.
///
/// - Watch: each part is a slice of the recording's file, written to
///   `.parts/<file>.<total>-<partSize>.<index>` in the recording folder just before it is
///   queued, and removed once its transfer finishes.
/// - Phone: received parts wait in `.parts/<file>/<total>-<partSize>/<index>`. When all are
///   there (checked after every file that arrives, so a join cut short by the app stopping
///   is done later), they are joined into a staged file, checked against the total size,
///   and put in place like a file sent whole; then the parts are removed.
/// - The watch keeps at most a window of parts queued per recording
///   (`TransferPolicy.window`, bounded by its free space), removes each slice once its
///   transfer finishes, and removes slices no transfer uses any more (`staleSlices`), so a
///   large file needs little extra space on the watch.
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

    enum PartError: Error, Equatable, CustomStringConvertible {
        case invalidMetadata
        case wrongSize(expected: Int64, actual: Int64?)
        case joinedWrongSize(expected: Int64, actual: Int64)
        /// The join was stopped (background time ran out); the parts are fine.
        case interrupted

        var description: String {
            switch self {
            case .invalidMetadata: "the part's metadata is invalid"
            case .wrongSize(let expected, let actual):
                "the part is \(actual.map(String.init) ?? "?") bytes, expected \(expected)"
            case .joinedWrongSize(let expected, let actual):
                "the joined file is \(actual) bytes, expected \(expected)"
            case .interrupted: "the join was stopped"
            }
        }
    }

    // MARK: Watch

    /// Where the watch writes a part before sending it. The name carries the layout, so a
    /// slice cut another way is never reused for this part.
    static func sliceURL(_ part: Part, in recording: URL) -> URL {
        recording.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(part.file).\(part.total)-\(part.partSize).\(part.index)")
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

    /// The slices in `recording` that no outstanding transfer uses (`inUse`, their file
    /// names): left by a transfer lost when the watch restarted, or cancelled before it
    /// finished. Removed before queuing; a part that has to go again is sliced again.
    static func staleSlices(in recording: URL, inUse: Set<String>) -> [URL] {
        let folder = recording.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !inUse.contains($0) }.sorted().map { folder.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    // MARK: Phone

    /// A file's parts are kept per layout (its total size and part size), so parts cut
    /// differently (a file that changed, or a build with another part size) never join with
    /// each other; acknowledgements name the layout, so the watch skips only parts it cut the
    /// same way.
    static func layoutKey(_ part: Part) -> String {
        "\(part.file)|\(part.total)|\(part.partSize)"
    }

    /// A part of the layout `key` names (its first), or nil if the key is not one.
    static func layout(_ key: String) -> Part? {
        let fields = key.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3, let total = Int64(fields[1]), let partSize = Int64(fields[2]),
            partSize > 0, partSize <= maximumPartSize, total > partSize
        else { return nil }
        return plan(file: String(fields[0]), size: total, partSize: partSize).first
    }

    /// Where the phone keeps the parts received so far of `part`'s file in its layout.
    static func receivedFolder(_ part: Part, in recording: URL) -> URL {
        recording.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(part.file, isDirectory: true)
            .appendingPathComponent("\(part.total)-\(part.partSize)", isDirectory: true)
    }

    enum Stored: Equatable {
        case stored, alreadyHad, replaced
    }

    /// Keeps a received part (moving `incoming` away; WatchConnectivity deletes it after the
    /// callback). One already held at the right size stays; a wrong size is refused. Parts
    /// of the same file in another layout are dropped.
    static func store(_ incoming: URL, as part: Part, in recording: URL) throws -> Stored {
        guard size(of: incoming) == part.length else {
            throw PartError.wrongSize(expected: part.length, actual: size(of: incoming))
        }
        let fm = FileManager.default
        let folder = receivedFolder(part, in: recording)
        let fileFolder = folder.deletingLastPathComponent()
        for other in (try? fm.contentsOfDirectory(atPath: fileFolder.path)) ?? [] where other != folder.lastPathComponent {
            try? fm.removeItem(at: fileFolder.appendingPathComponent(other))
        }
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

    /// The parts held of files still arriving, by layout (`layoutKey`), by index.
    static func held(in recording: URL) -> [String: [Int]] {
        let fm = FileManager.default
        let root = recording.appendingPathComponent(folderName, isDirectory: true)
        var held: [String: [Int]] = [:]
        for file in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let fileFolder = root.appendingPathComponent(file, isDirectory: true)
            for layout in (try? fm.contentsOfDirectory(atPath: fileFolder.path)) ?? [] {
                let fields = layout.split(separator: "-")
                guard fields.count == 2, let total = Int64(fields[0]), let partSize = Int64(fields[1]) else { continue }
                let indices = ((try? fm.contentsOfDirectory(atPath: fileFolder.appendingPathComponent(layout).path)) ?? [])
                    .compactMap(Int.init).sorted()
                if !indices.isEmpty { held["\(file)|\(total)|\(partSize)"] = indices }
            }
        }
        return held
    }

    /// A part of every layout whose parts are all held at the right sizes, ready to join.
    static func complete(in recording: URL) -> [Part] {
        held(in: recording).keys.sorted().compactMap(layout).filter { isComplete($0, in: recording) }
    }

    private static func isComplete(_ part: Part, in recording: URL) -> Bool {
        let folder = receivedFolder(part, in: recording)
        return plan(file: part.file, size: part.total, partSize: part.partSize).allSatisfy {
            size(of: folder.appendingPathComponent(String($0.index))) == $0.length
        }
    }

    /// Joins the parts of `part`'s file and layout into a staged file in the recording folder
    /// once all of them are held, checking every part's size and the total; nil while any is
    /// missing. The caller puts the staged file in place and removes the parts.
    /// `shouldContinue` is asked before each part; when it says no, the join stops with
    /// `PartError.interrupted`, removing the staged file and leaving the parts as they are.
    static func join(
        _ part: Part, in recording: URL, stagingPrefix: String, shouldContinue: () -> Bool = { true }
    ) throws -> URL? {
        guard isComplete(part, in: recording) else { return nil }
        let fm = FileManager.default
        let folder = receivedFolder(part, in: recording)
        let staged = recording.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)-\(part.file)")
        guard fm.createFile(atPath: staged.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            for each in plan(file: part.file, size: part.total, partSize: part.partSize) {
                guard shouldContinue() else { throw PartError.interrupted }
                let data = try Data(contentsOf: folder.appendingPathComponent(String(each.index)))
                guard Int64(data.count) == each.length else {
                    throw PartError.wrongSize(expected: each.length, actual: Int64(data.count))
                }
                try output.write(contentsOf: data)
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

    /// Removes every part of `file`, once it is in place (or its parts are unusable).
    static func removeParts(file: String, in recording: URL) {
        let fm = FileManager.default
        let root = recording.appendingPathComponent(folderName, isDirectory: true)
        try? fm.removeItem(at: root.appendingPathComponent(file, isDirectory: true))
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? fm.removeItem(at: root)
        }
    }

    /// The watch's slice of a part, once its transfer has finished either way: recreated if
    /// the part has to go again. Only removes a file inside a recording's `.parts`.
    static func removeSlice(at url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == folderName else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }
}
