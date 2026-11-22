import Foundation
import Testing

@testable import WaterKit

/// `scripts/anonymize-track <recording> <output> --labels <labels.json>`: a real paddling
/// recording and its reviewed stroke labels become a fixture with nothing left that says
/// where, when, or on whose device it was recorded, and the labels still fit the strokes.
@Suite struct FixtureExportTests {
    static let realStart = 1_809_165_600.25  // a plausible real session start, as in AnonymizerTests
    static let realOrigin = (lat: 47.612_345, lon: -122.345_678)

    /// A kayak recording as the iPhone exports it: a real place, date, session ID, clock
    /// anchors, monotonic motion stamps, altitude, magnetic heading and a free-text event.
    static func realRecording() -> (RawSession, [StrokeLabels.Stroke]) {
        let (paddle, strokes) = StrokeLabelsTests.paddle()
        var session = paddle
        session.meta = RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: realStart, endedAt: realStart + 120,
            device: .init(kind: "watch", model: "Watch7,5", os: "watchOS 26.1"),
            app: .init(version: "1.4.0", build: "88"),
            requestedRates: ["gps": 1, "motion": 100])
        session.gps = paddle.gps.map { fix in
            var moved = fix
            let offset = Geo.distance(lat1: 10, lon1: -30, lat2: fix.latitude, lon2: fix.longitude)
            let point = Geo.destination(lat: realOrigin.lat, lon: realOrigin.lon, bearing: 90, distance: offset)
            moved.latitude = point.lat
            moved.longitude = point.lon
            moved.altitude = 31.5
            moved.verticalAccuracy = 3
            return moved
        }
        session.motion = paddle.motion.map { sample in
            var stamped = sample
            stamped.monotonic = realStart + sample.t
            return stamped
        }
        session.hr = [HRSample(t: 30, bpm: 131)]
        session.heading = [HeadingSample(t: 2, magnetic: 101, trueHeading: 116.2, accuracy: 10)]
        session.events = [
            SessionEvent(t: 0, type: .start),
            // Auto-pause events must stay auto: as manual pauses they would stop stroke counting.
            SessionEvent(t: 40, type: .pause, data: ["auto": true]),
            SessionEvent(t: 46, type: .resume, data: ["auto": true]),
            SessionEvent(t: 60, type: .mark, data: ["note": "Alice at Lake Example", "lat": 47.6]),
            SessionEvent(t: 119, type: .stop),
        ]
        // A wall-clock correction after the paddling, so stroke times stay put.
        session.clockAnchors = [
            RawFormat.ClockAnchor(unix: realStart, mono: realStart),
            RawFormat.ClockAnchor(unix: realStart + 125.5, mono: realStart + 125),
        ]
        session.monotonicStart = realStart
        return (session, strokes)
    }

    /// labels.json as the review page exports it.
    static func reviewedLabels(_ strokes: [StrokeLabels.Stroke]) throws -> Data {
        let file = FixtureLabelsFile(
            sport: .kayak, source: "motion-review", description: "Flat water, watch on left wrist.",
            truth: .init(strokeTimes: strokes.map { .init(t: ($0.t * 1000).rounded() / 1000) }, excluded: []))
        return try file.encoded()
    }

    /// Every file in `folder` as text, gzip streams decompressed.
    static func contents(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            var data = try Data(contentsOf: folder.appendingPathComponent(name))
            if Gzip.isGzipped(data) { data = try Gzip.decompress(data) }
            result[name] = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    @Test func exportedFixtureKeepsLabelsAndLeaksNothing() throws {
        let (original, strokes) = Self.realRecording()
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let input = temp.url.appendingPathComponent("export")
        try RawSessionWriter.write(original, to: input)
        let read = try RawSessionReader.read(folder: input)
        #expect(FixtureCheck.problems(inFolder: input).count >= 3)

        let output = temp.url.appendingPathComponent("kayak-fixture")
        let anonymizer = Anonymizer()
        try anonymizer.exportFixture(from: input, to: output, labels: try Self.reviewedLabels(strokes))
        #expect(FixtureCheck.problems(inFolder: output) == [])

        // Nothing identifying survives anywhere in the output, compressed or not: no ID,
        // no date or Unix time near the real one, no position near the real place, and no
        // free text, altitude or magnetic heading.
        let files = try Self.contents(of: output)
        #expect(files.keys.contains("labels.json") && files.keys.contains("motion.ndjson.gz"))
        let id = original.meta.sessionId.uuidString
        var keys = Set<String>()
        var numbers: [Double] = []
        var strings: [String] = []
        var streamNumbers: [Double] = []
        var inStream = false
        func walk(_ value: JSONValue) {
            switch value {
            case .number(let number):
                numbers.append(number)
                if inStream { streamNumbers.append(number) }
            case .string(let text): strings.append(text)
            case .array(let items): items.forEach(walk)
            case .object(let object):
                keys.formUnion(object.keys)
                object.values.forEach(walk)
            case .null, .bool: break
            }
        }
        for (name, text) in files {
            #expect(!text.contains(id) && !text.contains(id.lowercased()), "\(name) has the session ID")
            let documents = name.hasSuffix(".ndjson.gz") ? text.split(separator: "\n").map(String.init) : [text]
            inStream = name != "labels.json"
            for document in documents {
                walk(try JSONDecoder().decode(JSONValue.self, from: Data(document.utf8)))
            }
        }
        #expect(!numbers.contains { abs($0 - Self.realStart) < 30 * 86_400 }, "a Unix time near the real date")
        // Label numbers are session times (FixtureCheck keeps them under 7 days), so a
        // stroke at 47.6 s is fine; the recording's own numbers must not be near the place.
        let near = streamNumbers.filter { abs($0 - Self.realOrigin.lat) < 0.5 || abs($0 - Self.realOrigin.lon) < 0.5 }
        #expect(near.isEmpty, "\(near.prefix(5))")
        #expect(!strings.contains { $0.contains("Alice") || $0.contains("Lake") })
        #expect(keys.isDisjoint(with: ["alt", "vacc", "mag", "note"]), "\(keys.sorted())")
        #expect(numbers.contains { abs($0 - Anonymizer.fakeStart) < 200 })

        // The labels are unchanged and still describe the fixture's strokes.
        let exported = try JSONDecoder().decode(
            FixtureLabelsFile.self, from: Data(contentsOf: output.appendingPathComponent("labels.json")))
        #expect(exported.strokeLabels?.strokes.map(\.t) == strokes.map { ($0.t * 1000).rounded() / 1000 })
        let fixture = try RawSessionReader.read(folder: output)
        let truth = try exported.strokeTruth()
        try FixtureAccuracyTests.check(
            .init(strokes: truth.strokes, strokeRateSPM: truth.strokeRateSPM), session: fixture,
            context: "anonymized fixture")
        // The detector finds the same strokes before and after (session time is kept).
        let before = StrokeAnalysis.detect(session: read).strokes.map(\.t)
        let after = StrokeAnalysis.detect(session: fixture).strokes.map(\.t)
        #expect(before.count == after.count)
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.002 })
    }

    @Test func badLabelsStopTheExportBeforeAnythingIsWritten() throws {
        let (original, strokes) = Self.realRecording()
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let input = temp.url.appendingPathComponent("export")
        try RawSessionWriter.write(original, to: input)
        let good = String(decoding: try Self.reviewedLabels(strokes), as: UTF8.self)
        let cases: [(String, String)] = [
            ("draft", good.replacingOccurrences(of: "motion-review", with: "draft")),
            ("sport", good.replacingOccurrences(of: #""kayak""#, with: #""canoe""#)),
            ("extra field", good.replacingOccurrences(of: #""v" : 1"#, with: #""v" : 1, "where" : "Lake Example""#)),
            (
                "past the end",
                good.replacingOccurrences(of: #""strokeTimes" : ["#, with: #""strokeTimes" : [{"t" : 500},"#)
            ),
            (
                "real date",
                good.replacingOccurrences(of: #""strokeTimes" : ["#, with: #""strokeTimes" : [{"t" : 1809165700},"#)
            ),
            ("stated count", good.replacingOccurrences(of: #""truth" : {"#, with: #""truth" : {"strokes" : 3,"#)),
        ]
        for (name, text) in cases {
            #expect(text != good, "\(name) did not change the labels")
            let output = temp.url.appendingPathComponent("out-\(name)")
            #expect(throws: FixtureLabelsError.self, "\(name)") {
                try Anonymizer().exportFixture(from: input, to: output, labels: Data(text.utf8))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(name)")
        }
    }
}
