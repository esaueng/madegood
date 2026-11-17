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
        try Self.replace(
            in: other.appendingPathComponent("meta.json"), #""unix" : 946728000"#, with: #""unix" : 1809165600"#)
        #expect(FixtureCheck.problems(inFolder: other).contains { $0.contains("synthetic anchor") })
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
