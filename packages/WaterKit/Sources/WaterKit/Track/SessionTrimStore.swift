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

    private struct LegacyRecord: Codable {
        let version: Int
        let start: Double
        let end: Double
    }

    private struct Record: Codable {
        struct Span: Codable {
            let start: Double
            let end: Double
        }

        let version: Int
        let keptSpans: [Span]
    }

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
        guard header.version == 1 || header.version == 2 else { throw Error.unsupportedVersion(header.version) }
        if header.version == 1 {
            let legacy = try decoder.decode(LegacyRecord.self, from: data)
            return try SessionTrim(start: legacy.start, end: legacy.end)
        }
        let record = try decoder.decode(Record.self, from: data)
        let spans = try record.keptSpans.map { span in
            guard span.start <= span.end else { throw SessionTrim.Error.invalidBounds }
            return span.start...span.end
        }
        return try SessionTrim(retaining: spans)
    }

    /// Atomically replaces a trim with retained spans on the original recording clock.
    public func save(_ trim: SessionTrim, for session: RawSession) throws {
        try trim.validate(in: session)
        let encoder = JSONEncoder()
        let data: Data
        if trim.retainedRanges.count == 1 {
            data = try encoder.encode(
                LegacyRecord(version: 1, start: trim.range.lowerBound, end: trim.range.upperBound))
        } else {
            let spans = trim.retainedRanges.map { Record.Span(start: $0.lowerBound, end: $0.upperBound) }
            data = try encoder.encode(Record(version: 2, keptSpans: spans))
        }
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
