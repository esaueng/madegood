import Foundation
import Testing

@testable import WaterKit

/// Each test starts from a correctly anonymized recording and plants one leak that a
/// careless or partial anonymization could leave behind. The check must catch every one.
@Suite struct FixtureCheckTests {
    /// Writes an anonymized recording into `temp` (which the caller keeps alive).
    static func anonymizedFolder(in temp: TempFolder) throws -> URL {
        let output = temp.url.appendingPathComponent("fixture")
        let session = Anonymizer().anonymize(AnonymizerTests.session(origin: (47.6, -122.4)))
        try RawSessionWriter.write(session, to: output, gzip: false)
        return output
    }

    static func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func replace(in file: URL, _ old: String, with new: String) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(old))
        try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func cleanAnonymizedFolderPasses() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        #expect(FixtureCheck.problems(inFolder: folder) == [])
    }

    @Test func rejectsTextInEventTypesAndData() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        let events = folder.appendingPathComponent("events.ndjson")
        try Self.append(#"{"ts":946728010,"type":"Alice at Lake Example"}"# + "\n", to: events)
        try Self.append(
            #"{"ts":946728011,"type":"mark","data":{"Alice":true,"timestamp":1809165600,"x":-122.3}}"# + "\n",
            to: events)
        let problems = FixtureCheck.problems(inFolder: folder)
        #expect(problems.contains { $0.contains("event types not allowed") })
        #expect(problems.contains { $0.contains("outside the allowed numeric fields") })
    }

    @Test func rejectsMagneticHeading() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        try Self.append(
            #"{"ts":946728012,"mag":40,"true":55,"acc":5}"# + "\n",
            to: folder.appendingPathComponent("heading.ndjson"))
        #expect(FixtureCheck.problems(inFolder: folder).contains { $0.contains("magnetic") })
    }

    @Test func rejectsLinesTheReaderWouldSkip() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        // A damaged line with a real position and date, between valid lines.
        let gps = folder.appendingPathComponent("gps.ndjson")
        let text = try String(contentsOf: gps, encoding: .utf8)
        var lines = text.split(separator: "\n").map(String.init)
        lines.insert(#"{"ts":1809165601,"lat":47.6,"lon":"-122.4"}"#, at: 5)
        try (lines.joined(separator: "\n") + "\n").write(to: gps, atomically: true, encoding: .utf8)
        #expect(FixtureCheck.problems(inFolder: folder).contains { $0.contains("skipped data") })
    }

    @Test func rejectsUnknownFieldsAndFiles() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        try Self.replace(
            in: folder.appendingPathComponent("hr.ndjson"), #""bpm":120"#, with: #""bpm":120,"where":"Seattle""#)
        try Self.replace(
            in: folder.appendingPathComponent("meta.json"), #""kind" : "phone""#,
            with: #""kind" : "phone", "name" : "Alice's iPhone""#)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let problems = FixtureCheck.problems(inFolder: folder)
        #expect(problems.contains("hr.ndjson: unknown fields [\"where\"]"))
        #expect(problems.contains("meta.json: unknown fields [\"device.name\"]"))
        #expect(problems.contains("unexpected file notes.txt"))
    }

    @Test func rejectsRealTimestampsBehindAFakeStart() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        let realOffset = 1_809_165_600.0 - Anonymizer.fakeStart
        // Real sample dates in one stream, a real end date, and a real clock anchor.
        let hr = folder.appendingPathComponent("hr.ndjson")
        try Self.replace(in: hr, #""ts":946728005"#, with: #""ts":\#(Int(Anonymizer.fakeStart + 5 + realOffset))"#)
        try Self.replace(
            in: folder.appendingPathComponent("meta.json"), #""endedAt" : 946730000"#,
            with: #""endedAt" : 1809167600"#)
        let problems = FixtureCheck.problems(inFolder: folder)
        #expect(problems.contains { $0.contains("hr timestamps are not on the anonymized timeline") })
        #expect(problems.contains { $0.contains("endedAt") })

        let otherTemp = try TempFolder()
        defer { withExtendedLifetime(otherTemp) {} }
        let other = try Self.anonymizedFolder(in: otherTemp)
        // A clock anchor would tie the fake timeline to a real wall-clock time.
        try Data(#"{"unix":1809165600,"mono":946728100}"#.utf8 + [0x0A])
            .write(to: other.appendingPathComponent(RawFormat.Stream.clock.fileName))
        #expect(FixtureCheck.problems(inFolder: other).contains { $0.contains("synthetic") })
    }

    @Test func labelsMustMatchTheSchemaAllTheWayDown() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        let labels = folder.appendingPathComponent("labels.json")

        let good =
            #"{"v":1,"sport":"kayak","source":"video","description":"Flat water.","license":"CC-BY-4.0","truth":{"strokes":812,"maneuvers":[{"t":1.5,"type":"tack"}]}}"#
        try Data(good.utf8).write(to: labels)
        #expect(FixtureCheck.problems(inFolder: folder) == [])

        let nested =
            #"{"v":1,"sport":"kayak","source":"video","license":"CC-BY-4.0","truth":{"owner":"Alice","lat":47.6,"lon":-122.4}}"#
        try Data(nested.utf8).write(to: labels)
        #expect(
            FixtureCheck.problems(inFolder: folder).contains {
                $0.contains("unknown fields [\"lat\", \"lon\", \"owner\"]")
            })

        let maneuver = #"{"v":1,"truth":{"maneuvers":[{"t":1,"type":"tack","where":"Seattle"}]}}"#
        try Data(maneuver.utf8).write(to: labels)
        #expect(FixtureCheck.problems(inFolder: folder).contains { $0.contains("truth.maneuvers") })

        try Data("Alice sailed at Lake Example on 2026-11-16 {".utf8).write(to: labels)
        #expect(FixtureCheck.problems(inFolder: folder).contains("labels.json: not a JSON object"))
    }

    @Test func gzipHeadersMayNotCarryNamesCommentsOrTimes() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let source = try Self.anonymizedFolder(in: temp)
        let hr = try Data(contentsOf: source.appendingPathComponent("hr.ndjson"))

        // A member with FNAME set and a name after the fixed header.
        var named = [UInt8](try Gzip.compress(hr))
        named[3] |= 0x08
        named.insert(contentsOf: Array("Alice-Seattle-2026-11-16.ndjson".utf8) + [0], at: 10)
        // A member with a real modification time.
        var timed = [UInt8](try Gzip.compress(hr))
        timed[4] = 0x60; timed[5] = 0x8f; timed[6] = 0xd3; timed[7] = 0x6b

        for (bytes, expected) in [(named, "file name"), (timed, "modification time")] {
            #expect(try Gzip.decompress(Data(bytes)) == hr)  // decoding hides the header
            try FileManager.default.removeItem(at: source.appendingPathComponent("hr.ndjson"))
            try? FileManager.default.removeItem(at: source.appendingPathComponent("hr.ndjson.gz"))
            try Data(bytes).write(to: source.appendingPathComponent("hr.ndjson.gz"))
            #expect(FixtureCheck.problems(inFolder: source).contains { $0.contains(expected) })
            try hr.write(to: source.appendingPathComponent("hr.ndjson"))
            try FileManager.default.removeItem(at: source.appendingPathComponent("hr.ndjson.gz"))
        }

        // Our own writer leaves the optional fields and MTIME empty.
        let headers = try Gzip.memberHeaders(try Gzip.compress(hr) + Gzip.compress(hr))
        #expect(headers.count == 2)
        #expect(headers.allSatisfy { !$0.hasOptionalFields && $0.modificationTime == 0 })
    }

    @Test func trackFilesAreCheckedStrictly() throws {
        let anonymized = Anonymizer().anonymize(AnonymizerTests.session(origin: (69.6, 18.9)).track())
        let clean = try TrackCodec.encode(anonymized)
        #expect(FixtureCheck.problems(inTrackFile: clean) == [])

        var text = String(decoding: try TrackCodec.encodeJSON(anonymized), as: UTF8.self)
        text = text.replacingOccurrences(of: #""v":1"#, with: #""v":1,"owner":"Alice""#)
        #expect(FixtureCheck.problems(inTrackFile: Data(text.utf8)).contains("track: unknown fields [\"owner\"]"))
    }
}
