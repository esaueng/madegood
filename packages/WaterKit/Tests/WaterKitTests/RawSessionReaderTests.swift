import Foundation
import Testing

@testable import WaterKit

/// Reading recordings. These folders are written in version 1 (device uptime in
/// `meta.clock`, motion and clock lines), so they also cover the old-version reader;
/// RawFormatVersionTests covers version 2.
@Suite struct RawSessionReaderTests {
    static let startUnix = 1_809_165_600.0
    static let startUptime = 5_000.0

    static func meta(endedAt: Double? = startUnix + 10) -> RawFormat.Meta {
        RawFormat.Meta(
            sessionId: UUID(uuidString: "6F1C2A3E-8A5B-4C1D-9E2F-0A1B2C3D4E5F")!,
            sport: .kayak,
            startedAt: startUnix,
            endedAt: endedAt,
            device: RawFormat.Device(kind: "watch", model: "Watch7,5", os: "watchOS 26.1"),
            app: RawFormat.App(version: "0.1.0", build: "1"),
            requestedRates: ["motion": 100, "gps": 1])
    }

    /// `meta.json` of version 1, with its device-uptime anchor at the start.
    static func encodeV1(_ meta: RawFormat.Meta) throws -> Data {
        try RawFormat.V1.encodeMeta(meta, clock: RawFormat.V1.ClockAnchor(unix: startUnix, uptime: startUptime))
    }

    static func motionLine(uptime: Double, ax: Double = 0) -> RawFormat.MotionLine {
        RawFormat.MotionLine(
            ts: uptime, userAcceleration: Vector3(x: ax, y: 0, z: 0),
            gravity: Vector3(x: 0, y: 0, z: -RawFormat.standardGravity), rotationRate: .zero, attitude: .identity)
    }

    @Test func sameSizeRawReplacementInvalidatesTheRevision() throws {
        let folder = try TempFolder()
        let name = RawFormat.Stream.gps.fileName
        let url = folder.url.appendingPathComponent(name)
        let original = try lines([RawFormat.GPSLine(ts: Self.startUnix + 4, lat: 0, lon: 0, hacc: 3)])
        let replacement = try lines([RawFormat.GPSLine(ts: Self.startUnix + 6, lat: 0, lon: 0, hacc: 3)])
        #expect(original.count == replacement.count)
        try folder.write(name, original)
        let revision = RawSessionReader.revision(of: folder.url)
        #expect(revision.map(\.name) == [name])

        try folder.write("track.json.gz", Data("derived".utf8))
        #expect(RawSessionReader.revision(of: folder.url) == revision)

        try folder.write(name, replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Self.startUnix)], ofItemAtPath: url.path)
        let replaced = RawSessionReader.revision(of: folder.url)
        #expect(replaced.map(\.size) == revision.map(\.size))
        #expect(replaced != revision)
    }

    @Test func canSkipTheMotionStream() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        try folder.write(
            "gps.ndjson", lines([RawFormat.GPSLine(ts: Self.startUnix + 1, lat: 0.0001, lon: 0.0002, hacc: 4)]))
        try folder.write(
            "motion.ndjson.gz", Gzip.compress(lines([Self.motionLine(uptime: Self.startUptime + 0.01, ax: 1)])))
        let full = try RawSessionReader.read(folder: folder.url)
        let light = try RawSessionReader.read(folder: folder.url, includeMotion: false)
        #expect(full.motion.count == 1)
        #expect(light.motion.isEmpty)
        #expect(light.gps == full.gps)
    }

    @Test func readsAllStreamsOntoTheSessionTimeline() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        try folder.write(
            "gps.ndjson",
            lines([
                RawFormat.GPSLine(ts: Self.startUnix + 1, lat: 0.0001, lon: 0.0002, hacc: 4, spd: 1.5, crs: 90),
                RawFormat.GPSLine(ts: Self.startUnix + 2, lat: 0.000_11, lon: 0.0002, hacc: 5),
            ]))
        try folder.write(
            "motion.ndjson.gz",
            Gzip.compress(
                lines([
                    Self.motionLine(uptime: Self.startUptime + 0.01, ax: 1),
                    Self.motionLine(uptime: Self.startUptime + 0.02, ax: 2),
                ])))
        try folder.write("hr.ndjson", lines([RawFormat.HRLine(ts: Self.startUnix + 3, bpm: 99)]))
        try folder.write(
            "heading.ndjson",
            lines([
                RawFormat.HeadingLine(ts: Self.startUnix + 4, mag: 10, trueHeading: 12, acc: 5)
            ]))
        try folder.write(
            "events.ndjson",
            lines([
                RawFormat.EventLine(ts: Self.startUnix, type: .start),
                RawFormat.EventLine(ts: Self.startUnix + 5, type: .mark, data: ["n": 1]),
            ]))

        let session = try RawSessionReader.read(folder: folder.url)

        #expect(session.issues.isEmpty)
        #expect(session.meta.sport == .kayak)
        #expect(session.gps.map(\.t) == [1, 2])
        #expect(session.gps[0].speed == 1.5)
        #expect(session.gps[1].speed == nil)
        #expect(session.motion.count == 2)
        // Converted to absolute monotonic time: about 0.2 µs resolution at today's times.
        #expect(abs(session.motion[0].t - 0.01) < 1e-6)
        #expect(session.motion[1].userAcceleration.x == 2)
        #expect(session.hr.map(\.t) == [3])
        #expect(session.heading.first?.trueHeading == 12)
        #expect(session.events.map(\.type) == [.start, .mark])
        #expect(session.duration == 10)

        let track = session.track()
        #expect(track.gps.count == 2)
        #expect(track.startedAt == Date(timeIntervalSince1970: Self.startUnix))
        #expect(session.samples().map(\.t).isSorted())
    }

    @Test func laterClockAnchorsCorrectMotionTimes() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        // At uptime +60 s the wall clock was found to be 0.5 s ahead of the first anchor.
        try folder.write(
            "clock.ndjson",
            lines([
                RawFormat.V1.ClockAnchor(unix: Self.startUnix + 60.5, uptime: Self.startUptime + 60)
            ]))
        try folder.write(
            "motion.ndjson",
            lines([
                Self.motionLine(uptime: Self.startUptime + 30),
                Self.motionLine(uptime: Self.startUptime + 61),
            ]))

        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.motion.map(\.t) == [30, 61.5])
        #expect(session.clockAnchors.count == 2)
    }

    @Test func toleratesTruncatedAndInvalidLines() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta(endedAt: nil)))
        var gps = try lines([
            RawFormat.GPSLine(ts: Self.startUnix + 1, lat: 0, lon: 0),
            RawFormat.GPSLine(ts: Self.startUnix + 2, lat: 0, lon: 0),
        ])
        gps.append(Data("{\"ts\":1,\"lat\":\"x\"}\r\n\n".utf8))  // invalid middle line, CRLF, blank line
        gps.append(try RawFormat.line(RawFormat.GPSLine(ts: Self.startUnix + 3, lat: 0, lon: 0)))
        gps.append(Data("{\"ts\":1809165604,\"la".utf8))  // cut off mid-write
        try folder.write("gps.ndjson", gps)

        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.gps.map(\.t) == [1, 2, 3])
        #expect(session.issues.count == 2)
        #expect(session.issues[0].line == 3)
        #expect(session.issues[1] == RawReadIssue(file: "gps.ndjson", line: 6, kind: .truncatedLine))
        // No endedAt: duration comes from the last sample.
        #expect(session.duration == 3)
    }

    @Test func readsTheCompletePartOfATruncatedGzipStream() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        // The recorder appends one gzip member per flush; the last flush was cut off.
        let flush1 = try Gzip.compress(
            lines((0..<50).map { Self.motionLine(uptime: Self.startUptime + Double($0) / 100) }))
        let flush2 = try Gzip.compress(
            lines((50..<100).map { Self.motionLine(uptime: Self.startUptime + Double($0) / 100) }))
        try folder.write("motion.ndjson.gz", flush1 + flush2.prefix(flush2.count / 2))

        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.motion.count >= 50)
        #expect(session.motion.count < 100)
        #expect(session.issues.contains(RawReadIssue(file: "motion.ndjson.gz", line: nil, kind: .truncatedFile)))
    }

    @Test func aDamagedStreamDoesNotHideTheOthers() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        try folder.write("gps.ndjson", lines([RawFormat.GPSLine(ts: Self.startUnix + 1, lat: 0, lon: 0)]))
        // The first motion flush was cut off after one byte of its gzip header.
        try folder.write("motion.ndjson.gz", Data([0x1f]))
        // The heading stream's header is corrupt.
        try folder.write("heading.ndjson.gz", Data([0x1f, 0x8b, 0x08, 0xff, 0xff, 0xff, 0xff]))

        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.gps.count == 1)
        #expect(session.motion.isEmpty && session.heading.isEmpty)
        let unreadable = session.issues.filter {
            if case .unreadableFile = $0.kind { true } else { false }
        }
        #expect(Set(unreadable.map(\.file)) == ["motion.ndjson.gz", "heading.ndjson.gz"])
    }

    @Test func missingStreamsAreEmpty() throws {
        let folder = try TempFolder()
        try folder.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.gps.isEmpty && session.motion.isEmpty && session.hr.isEmpty)
        #expect(session.issues.isEmpty)
    }

    @Test func rejectsBadFolders() throws {
        let empty = try TempFolder()
        #expect(throws: RawSessionReader.Error.self) { try RawSessionReader.read(folder: empty.url) }

        let future = try TempFolder()
        try future.write(RawFormat.metaFileName, Data(#"{"format":"madegood-raw","version":3}"#.utf8))
        #expect {
            try RawSessionReader.read(folder: future.url)
        } throws: { error in
            if case RawSessionReader.Error.unsupportedVersion(3) = error { true } else { false }
        }

        let foreign = try TempFolder()
        try foreign.write(RawFormat.metaFileName, Data(#"{"format":"gpx","version":1}"#.utf8))
        #expect {
            try RawSessionReader.read(folder: foreign.url)
        } throws: { error in
            if case RawSessionReader.Error.unsupportedFormat("gpx") = error { true } else { false }
        }

        let both = try TempFolder()
        try both.write(RawFormat.metaFileName, Self.encodeV1(Self.meta()))
        try both.write("hr.ndjson", Data())
        try both.write("hr.ndjson.gz", Data())
        #expect {
            try RawSessionReader.read(folder: both.url)
        } throws: { error in
            if case RawSessionReader.Error.bothPlainAndGzipped("hr") = error { true } else { false }
        }
    }

    @Test func metaRoundTripsAndOmitsDeviceName() throws {
        let data = try RawFormat.encodeMeta(Self.meta())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"madegood-raw\""))
        #expect(text.contains("\"version\" : 2"))
        #expect(!text.lowercased().contains("name"))
        #expect(!text.contains("uptime") && !text.contains("clock"))
        let decoded = try JSONDecoder().decode(RawFormat.Meta.self, from: data)
        #expect(decoded == Self.meta())
    }

    @Test func linesRejectNonFiniteNumbers() {
        #expect(throws: EncodingError.self) {
            try RawFormat.line(RawFormat.HRLine(ts: 0, bpm: .nan))
        }
    }

    @Test func headingUsesTrueKey() throws {
        let line = String(decoding: try RawFormat.line(RawFormat.HeadingLine(ts: 1, trueHeading: 5)), as: UTF8.self)
        #expect(line.contains("\"true\":5"))
        #expect(line.hasSuffix("\n"))
    }
}

// MARK: Helpers

func lines(_ values: [some Encodable]) throws -> Data {
    try values.reduce(into: Data()) { $0.append(try RawFormat.line($1)) }
}

/// A temporary directory removed when the value is released.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("waterkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ data: Data) throws {
        try data.write(to: url.appendingPathComponent(name))
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

extension Array where Element == Double {
    func isSorted() -> Bool {
        zip(self, dropFirst()).allSatisfy { $0 <= $1 }
    }
}
