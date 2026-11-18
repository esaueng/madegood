import Foundation

/// Stores one replaceable local trim per session. Supply a directory outside the raw
/// recording tree, since raw sharing archives the entire recording folder.
/// The caller serializes edits to a session and removes its trim when it is deleted.
public struct SessionTrimStore: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedVersion(Int)
    }

    private struct Header: Decodable {
        let version: Int
    }

    private struct Record: Codable {
        let version: Int
        let start: Double
        let end: Double
    }

    private static let version = 1
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Missing metadata means the original. Malformed or newer metadata throws;
    /// callers can show the original while surfacing the error and preserving the file.
    /// Creating a selection validates these bounds against the currently readable source.
    public func load(sessionId: UUID) throws -> SessionTrim? {
        let data: Data
        do {
            data = try Data(contentsOf: url(for: sessionId))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.version == Self.version else { throw Error.unsupportedVersion(header.version) }
        let record = try decoder.decode(Record.self, from: data)
        return try SessionTrim(start: record.start, end: record.end)
    }

    /// Atomically replaces a trim with a range on the original recording's timeline.
    public func save(_ trim: SessionTrim, for session: RawSession) throws {
        try trim.validate(in: session)
        let record = Record(version: Self.version, start: trim.range.lowerBound, end: trim.range.upperBound)
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: session.meta.sessionId), options: .atomic)
    }

    /// Removes only edit metadata. Repeated restores are safe.
    public func restoreOriginal(sessionId: UUID) throws {
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
