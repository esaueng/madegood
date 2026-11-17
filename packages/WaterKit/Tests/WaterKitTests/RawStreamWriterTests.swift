import Foundation
import Testing

@testable import WaterKit

@Suite struct RawStreamWriterTests {
    static func line(_ i: Int) -> RawFormat.HRLine { RawFormat.HRLine(ts: Double(i), bpm: 100) }

    @Test func writesOneReadableMemberPerFlush() throws {
        let folder = try TempFolder()
        try RawFormat.encodeMeta(RawSessionReaderTests.meta()).write(to: folder.url.appendingPathComponent("meta.json"))
        let writer = RawStreamWriter(stream: .hr, folder: folder.url)
        writer.append(Self.line(1))
        #expect(writer.flushAndWait())
        writer.append(Self.line(2))
        writer.append(Self.line(3))
        #expect(writer.flushAndWait())

        let data = try Data(contentsOf: writer.url)
        #expect(String(decoding: try Gzip.decompress(data), as: UTF8.self).split(separator: "\n").count == 3)
        #expect(writer.status == RawStreamWriter.Status(lines: 3, dropped: 0, lastError: nil))
    }

    @Test func keepsUnwrittenLinesAndRetriesAfterAWriteFailure() throws {
        let folder = try TempFolder()
        let writer = RawStreamWriter(stream: .hr, folder: folder.url)
        // Make the target unwritable: a directory where the file should be.
        try FileManager.default.createDirectory(at: writer.url, withIntermediateDirectories: false)
        writer.append(Self.line(1))
        writer.append(Self.line(2))

        #expect(!writer.flushAndWait())
        #expect(writer.status.lastError != nil)
        #expect(writer.status.dropped == 0)

        // Space is back: the retained lines are written ahead of newer ones.
        try FileManager.default.removeItem(at: writer.url)
        writer.append(Self.line(3))
        #expect(writer.flushAndWait())
        #expect(writer.status.lastError == nil)
        let text = String(decoding: try Gzip.decompress(Data(contentsOf: writer.url)), as: UTF8.self)
        let times = text.split(separator: "\n").map { line in
            try? JSONDecoder().decode(RawFormat.HRLine.self, from: Data(line.utf8)).ts
        }
        #expect(times == [1, 2, 3])
    }

    @Test func countsLinesItCannotKeep() throws {
        let folder = try TempFolder()
        let writer = RawStreamWriter(stream: .hr, folder: folder.url, maxRetainedBytes: 10)
        try FileManager.default.createDirectory(at: writer.url, withIntermediateDirectories: false)
        writer.append(Self.line(1))
        writer.append(Self.line(2))

        #expect(!writer.flushAndWait())
        #expect(writer.status.dropped == 2)
        #expect(writer.status.lastError != nil)

        // Storage recovers: later writes succeed, but the loss stays on record.
        try FileManager.default.removeItem(at: writer.url)
        writer.append(Self.line(3))
        #expect(writer.flushAndWait())
        #expect(writer.status.lastError == nil)
        #expect(writer.status.dropped == 2)
    }

    @Test func unencodableLinesAreCountedAsDropped() {
        let writer = RawStreamWriter(stream: .hr, folder: FileManager.default.temporaryDirectory)
        writer.append(RawFormat.HRLine(ts: 0, bpm: .nan))
        #expect(writer.status.dropped == 1)
        #expect(writer.status.lines == 0)
    }
}
