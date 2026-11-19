import Foundation
import Testing

@testable import WaterKit

/// Review of #87: conversion streams through gzip, leaves out everything that is not a
/// recording file, and ties on an anchor stay in the earlier segment.
@Suite struct RawConversionStreamTests {
    static let start = 946_684_800.0
    static let uptime0 = 5_000.0

    static func meta() -> RawFormat.Meta {
        RawFormat.Meta(
            sessionId: UUID(), sport: .sup, startedAt: start, endedAt: start + 60,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
    }

    static func motionLines(_ count: Int, from first: Int = 0) throws -> Data {
        var data = Data()
        for i in first..<(first + count) {
            data.append(
                try RawFormat.line(
                    RawFormat.MotionLine(
                        ts: uptime0 + Double(i) / 100, userAcceleration: Vector3(x: Double(i % 7), y: 0, z: 0),
                        gravity: Vector3(x: 0, y: 0, z: -9.8), rotationRate: .zero, attitude: .identity)))
        }
        return data
    }

    /// Feeds `data` to the streaming inflater `size` bytes at a time.
    static func inflate(_ data: Data, chunk size: Int) throws -> (Data, Bool) {
        var offset = 0
        var output = Data()
        let complete = try Gzip.inflateStream(
            reading: {
                guard offset < data.count else { return nil }
                let end = min(offset + size, data.count)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            }, emit: { output.append($0) })
        return (output, complete)
    }

    @Test func streamingInflateHandlesMembersPaddingAndTruncation() throws {
        let parts = try (0..<3).map { try Gzip.compress(Self.motionLines(200, from: $0 * 200)) }
        let joined = parts.reduce(Data(), +)
        let whole = try Gzip.decompress(joined)
        for size in [1, 7, 4096, 1 << 20] {
            let (out, complete) = try Self.inflate(joined, chunk: size)
            #expect(complete)
            #expect(out == whole)
        }
        // Zero padding after the last member ends the stream cleanly.
        #expect(try Self.inflate(joined + Data(count: 16), chunk: 5).1)
        // A truncated last member: everything readable, and not complete, as the batch API.
        let cut = joined.prefix(joined.count - parts[2].count / 2)
        let expected = try Gzip.decompressAvailable(Data(cut))
        for size in [3, 1000, 1 << 20] {
            let (out, complete) = try Self.inflate(Data(cut), chunk: size)
            #expect(!complete)
            #expect(out == expected.data)
        }
        #expect(throws: Gzip.Error.self) { _ = try Self.inflate(Data("not gzip".utf8), chunk: 4) }
    }

    @Test func streamingWriterRoundTrips() throws {
        var compressed = Data()
        let writer = try Gzip.Writer { compressed.append($0) }
        var plain = Data()
        for i in 0..<500 {
            let line = try Self.motionLines(10, from: i * 10)
            plain.append(line)
            try writer.write(line)
        }
        try writer.finish()
        #expect(try Gzip.decompress(compressed) == plain)
    }

    /// A version 1 folder with gzipped streams written as several members, the last cut off,
    /// plus the files an interrupted watch transfer and the analysis leave behind.
    static func writeV1(to folder: URL, lines: Int, members: Int, truncateLast: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RawFormat.V1.encodeMeta(meta(), clock: .init(unix: start, uptime: uptime0))
            .write(to: folder.appendingPathComponent(RawFormat.metaFileName))
        let per = lines / members
        var motion = Data()
        for m in 0..<members {
            var member = try Gzip.compress(motionLines(per, from: m * per))
            if truncateLast, m == members - 1 { member = member.prefix(member.count / 2) }
            motion.append(member)
        }
        try motion.write(to: folder.appendingPathComponent("motion.ndjson.gz"))
        try Gzip.compress(
            RawFormat.line(RawFormat.V1.ClockAnchor(unix: start + 30.5, uptime: uptime0 + 30)))
            .write(to: folder.appendingPathComponent("clock.ndjson.gz"))
        try RawFormat.line(RawFormat.EventLine(ts: start, type: .start))
            .write(to: folder.appendingPathComponent("events.ndjson"))
        // An interrupted transfer's staging copy (raw uptime) and the derived track.
        try Gzip.compress(RawFormat.line(RawFormat.V1.ClockAnchor(unix: start, uptime: uptime0)))
            .write(to: folder.appendingPathComponent(".incoming-\(UUID().uuidString)-clock.ndjson.gz"))
        try Data("derived".utf8).write(to: folder.appendingPathComponent("track.json.gz"))
    }

    @Test func conversionKeepsOnlyRecordingFilesAndStreamsTruncatedMembers() throws {
        let temp = try TempFolder()
        let v1 = temp.url.appendingPathComponent("v1")
        let v2 = temp.url.appendingPathComponent("v2")
        try Self.writeV1(to: v1, lines: 3000, members: 3, truncateLast: true)
        var reported: [Double] = []
        #expect(try RawFormatConversion.convertToCurrent(folder: v1, into: v2) { reported.append($0) })
        let names = try FileManager.default.contentsOfDirectory(atPath: v2.path).sorted()
        #expect(names == ["clock.ndjson.gz", "events.ndjson", "meta.json", "motion.ndjson.gz"])
        #expect(reported.first == 0 && reported.last == 1)
        #expect(reported == reported.sorted())

        // Every complete line of the readable part, on the monotonic clock; same as reading v1.
        let original = try RawSessionReader.read(folder: v1)
        let converted = try RawSessionReader.read(folder: v2)
        #expect(converted.meta.version == RawFormat.version)
        #expect(converted.motion.count == original.motion.count)
        #expect(converted.motion.count >= 2000 && converted.motion.count < 3000)
        #expect(zip(converted.motion, original.motion).allSatisfy { abs($0.t - $1.t) < 1e-6 })
        #expect(converted.clockAnchors == original.clockAnchors)
        let text = String(decoding: try Gzip.decompress(Data(contentsOf: v2.appendingPathComponent("clock.ndjson.gz"))), as: UTF8.self)
        #expect(!text.contains("uptime"))
    }

    @Test func aLongStreamConvertsChunkByChunk() throws {
        let temp = try TempFolder()
        let v1 = temp.url.appendingPathComponent("v1")
        let v2 = temp.url.appendingPathComponent("v2")
        // About 60 minutes at 100 Hz: 360,000 lines, tens of MB uncompressed.
        try Self.writeV1(to: v1, lines: 360_000, members: 60, truncateLast: false)
        let source = v1.appendingPathComponent("motion.ndjson.gz")
        let compressedSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        var reads = 0
        let chunk = 64 * 1024
        try RawFormatConversion.convertLines(
            from: source, to: v2.appendingPathComponentCreatingFolder("motion.ndjson.gz"), gzip: true,
            chunk: chunk, progress: { _ in reads += 1 }
        ) { (line: RawFormat.MotionLine) in line }
        // Read in chunks, never the whole file at once.
        #expect(compressedSize > 4 * chunk)
        #expect(reads >= compressedSize / chunk)
        let out = try Gzip.decompress(Data(contentsOf: v2.appendingPathComponent("motion.ndjson.gz")))
        #expect(out.split(separator: 0x0A).count == 360_000)
    }

    /// Scoped re-check of #87, finding 4: only a truncated or damaged last member is read up
    /// to where it ends; any other inflate error fails the conversion and leaves nothing.
    @Test func anInflateErrorFailsTheConversionAndRemovesItsOutput() throws {
        let temp = try TempFolder()
        let v1 = temp.url.appendingPathComponent("v1")
        try Self.writeV1(to: v1, lines: 3000, members: 3, truncateLast: false)
        let limit = 10_000  // far below the motion stream's inflated size

        // Into a new folder: it is removed.
        let fresh = temp.url.appendingPathComponent("fresh")
        #expect(throws: Gzip.Error.self) {
            try RawFormatConversion.exportCopy(folder: v1, into: fresh, inflateLimit: limit) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))

        // Into an existing folder: what it wrote goes, what was there stays.
        let existing = temp.url.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("other.txt"))
        #expect(throws: Gzip.Error.self) {
            try RawFormatConversion.exportCopy(folder: v1, into: existing, inflateLimit: limit) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["other.txt"])

        // A motion stream that is not gzip at all fails too, instead of converting to nothing.
        try Data("not gzip at all".utf8).write(to: v1.appendingPathComponent("motion.ndjson.gz"))
        let notGzip = temp.url.appendingPathComponent("notGzip")
        #expect(throws: Gzip.Error.self) { try RawFormatConversion.exportCopy(folder: v1, into: notGzip) }
        #expect(!FileManager.default.fileExists(atPath: notGzip.path))

        // Within the limit the same recording converts.
        try Self.writeV1(to: v1, lines: 3000, members: 3, truncateLast: true)
        let ok = temp.url.appendingPathComponent("ok")
        try RawFormatConversion.exportCopy(folder: v1, into: ok)
        #expect(try RawSessionReader.read(folder: ok).motion.count >= 2000)
    }

    @Test func aSampleOnAnAnchorStaysInTheEarlierSegment() throws {
        let temp = try TempFolder()
        let folder = temp.url
        try RawFormat.encodeMeta(Self.meta()).write(to: folder.appendingPathComponent(RawFormat.metaFileName))
        // The wall clock was corrected +100 s at 10 s in; one sample rounds onto the anchor.
        try RawFormat.line(RawFormat.ClockAnchor(unix: Self.start + 110, mono: Self.start + 10))
            .write(to: folder.appendingPathComponent("clock.ndjson"))
        var motion = Data()
        for mono in [Self.start + 9.99, Self.start + 10, Self.start + 10.01] {
            motion.append(
                try RawFormat.line(
                    RawFormat.MotionLine(
                        ts: mono, userAcceleration: .zero, gravity: .zero, rotationRate: .zero, attitude: .identity)))
        }
        try motion.write(to: folder.appendingPathComponent("motion.ndjson"))
        let times = try RawSessionReader.read(folder: folder).motion.map(\.t)
        #expect(abs(times[0] - 9.99) < 1e-6)
        #expect(abs(times[1] - 10) < 1e-6)  // on the anchor: earlier segment
        #expect(abs(times[2] - 110.01) < 1e-6)
    }
}

extension URL {
    fileprivate func appendingPathComponentCreatingFolder(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return appendingPathComponent(name)
    }
}
