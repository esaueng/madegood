import Foundation

/// A name and notes the user gave a session. Both stay on the device: they are not part
/// of the raw recording or track formats (see docs/formats.md, "Local session details").
public struct SessionDetails: Equatable, Hashable, Sendable {
    /// Longest name kept, in characters.
    public static let maxNameLength = 100
    /// Longest notes kept, in characters.
    public static let maxNotesLength = 10_000

    /// One line, no surrounding spaces; empty means the session has no name.
    public private(set) var name: String
    /// Free text without leading or trailing blank space; empty means no notes.
    public private(set) var notes: String

    /// Normalizes what was typed: a name becomes one line without surrounding spaces,
    /// notes lose leading and trailing blank space, and both are cut to their limits.
    public init(name: String = "", notes: String = "") {
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        self.name = Self.trimmed(String(Self.trimmed(line).prefix(Self.maxNameLength)))
        self.notes = Self.trimmed(String(Self.trimmed(notes).prefix(Self.maxNotesLength)))
    }

    public var isEmpty: Bool { name.isEmpty && notes.isEmpty }

    private static func trimmed(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(text[first...last])
    }
}

/// Stores one replaceable name and notes file per session. Supply a directory outside
/// the raw recording tree, since raw sharing archives the entire recording folder.
/// The caller removes a session's file when the session is deleted.
public struct SessionDetailsStore: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedVersion(Int)
    }

    private struct Header: Decodable {
        let version: Int
    }

    private struct Record: Codable {
        let version: Int
        var name: String?
        var notes: String?
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Nil when the session has no saved name or notes. Malformed or newer files throw;
    /// callers keep the file and leave it unedited rather than overwrite what they can't read.
    public func load(sessionId: UUID) throws -> SessionDetails? {
        let data: Data
        do {
            data = try Data(contentsOf: url(for: sessionId))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.version == 1 else { throw Error.unsupportedVersion(header.version) }
        let record = try decoder.decode(Record.self, from: data)
        let details = SessionDetails(name: record.name ?? "", notes: record.notes ?? "")
        return details.isEmpty ? nil : details
    }

    /// Atomically replaces the session's file; empty details remove it.
    public func save(_ details: SessionDetails, sessionId: UUID) throws {
        guard !details.isEmpty else { return try remove(sessionId: sessionId) }
        let record = Record(
            version: 1, name: details.name.isEmpty ? nil : details.name,
            notes: details.notes.isEmpty ? nil : details.notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: sessionId), options: .atomic)
    }

    /// Removes the session's file. Repeated removes are safe.
    public func remove(sessionId: UUID) throws {
        do {
            try FileManager.default.removeItem(at: url(for: sessionId))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private func url(for sessionId: UUID) -> URL {
        directory.appendingPathComponent(sessionId.uuidString.lowercased() + ".json")
    }
}
