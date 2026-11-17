import Foundation
import Testing

@testable import WaterKit

#if canImport(FoundationXML)
    import FoundationXML
#endif

@Suite struct GPXWriterTests {
    // Synthetic values only: positions near a fake origin, a fixed 2000-01-01 start.
    static let start = Date(timeIntervalSince1970: 946_728_000)  // 2000-01-01T12:00:00Z
    static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    static func fix(_ t: Double, lat: Double = 10, lon: Double = -30, alt: Double? = nil,
                    speed: Double? = nil, course: Double? = nil) -> GPSFix {
        GPSFix(t: t, latitude: lat, longitude: lon, altitude: alt, speed: speed, course: course)
    }

    static func track(_ gps: [GPSFix], events: [SessionEvent] = [], sport: Sport = .sailing) -> Track {
        Track(sessionId: id, sport: sport, startedAt: start, gps: gps, events: events)
    }

    // MARK: Well-formed output

    @Test func writesWellFormedGPX() throws {
        let track = Self.track(
            [
                Self.fix(0, lat: 10.000_000_04, lon: -30, alt: 1.26, speed: 2.5, course: 359.96),
                Self.fix(1, lat: 10.000_01, lon: -29.999_99, speed: 2.504),
                Self.fix(2.25, lat: 10.000_02, lon: -29.999_98, course: 45),
                Self.fix(3, lat: 10.000_03, lon: -29.999_97),
            ],
            sport: .kayak)
        let parsed = try GPXParse(GPXWriter().data(for: track))

        #expect(parsed.rootName == "gpx")
        #expect(parsed.rootNamespace == GPXWriter.gpxNamespace)
        #expect(parsed.rootAttributes["version"] == "1.1")
        #expect(parsed.rootAttributes["creator"] == "MadeGood")
        #expect(parsed.texts("name") == ["Kayak", "Kayak"])
        #expect(parsed.texts("type") == ["kayak"])
        #expect(parsed.segments.count == 1)
        #expect(parsed.segments[0].map(\.lat) == ["10", "10.00001", "10.00002", "10.00003"])
        #expect(parsed.segments[0].map(\.lon) == ["-30", "-29.99999", "-29.99998", "-29.99997"])
        #expect(parsed.texts("time") == [
            "2000-01-01T12:00:00.000Z",  // metadata
            "2000-01-01T12:00:00.000Z", "2000-01-01T12:00:01.000Z", "2000-01-01T12:00:02.250Z",
            "2000-01-01T12:00:03.000Z",
        ])
        #expect(parsed.texts("ele") == ["1.3"])
        // Garmin TrackPointExtension v2, namespaced; 359.96° rounds to 360 and wraps to 0.
        #expect(parsed.texts("speed", namespace: GPXWriter.trackPointExtensionNamespace) == ["2.5", "2.5"])
        #expect(parsed.texts("course", namespace: GPXWriter.trackPointExtensionNamespace) == ["0", "45"])
        #expect(parsed.count("extensions") == 3)
    }

    @Test func timesAreMillisecondUTC() throws {
        let track = Self.track([Self.fix(0.1), Self.fix(59.999), Self.fix(3600.5)])
        let times = try GPXParse(GPXWriter().data(for: track)).texts("time").dropFirst()
        #expect(Array(times) == ["2000-01-01T12:00:00.100Z", "2000-01-01T12:00:59.999Z", "2000-01-01T13:00:00.500Z"])
    }

    @Test func emptyTrackHasNoSegments() throws {
        let parsed = try GPXParse(GPXWriter().data(for: Self.track([])))
        #expect(parsed.count("trk") == 1)
        #expect(parsed.segments.isEmpty)
    }

    // MARK: Ordering and filtering

    @Test func sortsFixesByTimeKeepingStoredOrderForTies() {
        let track = Self.track([
            Self.fix(2, lat: 2), Self.fix(0, lat: 0), Self.fix(1, lat: 1.1), Self.fix(1, lat: 1.2), Self.fix(3, lat: 3),
        ])
        let segments = GPXWriter().segments(of: track)
        #expect(segments.count == 1)
        #expect(segments[0].map(\.latitude) == [0, 1.1, 1.2, 2, 3])
    }

    @Test func skipsFixesWithoutValidCoordinates() {
        let track = Self.track([
            Self.fix(0, lat: 0, lon: 0),  // the fake origin is a valid position
            Self.fix(1, lat: .nan),
            Self.fix(2, lon: .infinity),
            Self.fix(3, lat: 90.5),
            Self.fix(4, lon: -180.01),
            GPSFix(t: .nan, latitude: 1, longitude: 1),
            Self.fix(5, lat: -90, lon: 180),
        ])
        let fixes = GPXWriter().segments(of: track).flatMap { $0 }
        #expect(fixes.map(\.t) == [0, 5])
    }

    @Test func omitsInvalidSpeedCourseAndAltitude() {
        let point = GPXWriter.trackPoint(
            GPSFix(t: 0, latitude: 1, longitude: 2, altitude: .nan, speed: -1, course: .infinity), startedAt: Self.start)
        #expect(point == #"<trkpt lat="1" lon="2"><time>2000-01-01T12:00:00.000Z</time></trkpt>"#)
    }

    // MARK: Segments

    @Test func splitsAtGapsLongerThanThreshold() {
        let track = Self.track([0, 1, 2, 32, 33, 63.5, 64].map { Self.fix($0) })
        let segments = GPXWriter().segments(of: track)
        // 2 → 32 is exactly the 30 s threshold (no split); 33 → 63.5 is longer (split).
        #expect(segments.map { $0.map(\.t) } == [[0, 1, 2, 32, 33], [63.5, 64]])

        let tight = GPXWriter(segmentGap: 5).segments(of: track)
        #expect(tight.map { $0.map(\.t) } == [[0, 1, 2], [32, 33], [63.5, 64]])
    }

    @Test func splitsAtPauseResumePairs() {
        let track = Self.track(
            [0, 1, 2, 3, 4, 5, 6, 7, 8].map { Self.fix($0) },
            events: [
                SessionEvent(t: 6.5, type: .resume),  // stored out of order
                SessionEvent(t: 1.5, type: .pause),
                SessionEvent(t: 3, type: .resume),  // a fix exactly at resume starts the new segment
                SessionEvent(t: 5.5, type: .pause),
                SessionEvent(t: 0.5, type: .resume),  // resume without a pause: ignored
                SessionEvent(t: 7.5, type: .pause),  // never resumed: ignored
                SessionEvent(t: 4.5, type: .mark),
            ])
        let segments = GPXWriter().segments(of: track)
        #expect(segments.map { $0.map(\.t) } == [[0, 1, 2], [3, 4, 5, 6], [7, 8]])
    }

    @Test func pauseResumeWithNoFixesBetweenSplitsOnce() {
        let track = Self.track(
            [0, 1, 2, 3].map { Self.fix($0) },
            events: [
                SessionEvent(t: 1.2, type: .pause), SessionEvent(t: 1.4, type: .resume),
                SessionEvent(t: 1.6, type: .pause), SessionEvent(t: 1.8, type: .resume),
            ])
        #expect(GPXWriter().segments(of: track).map { $0.map(\.t) } == [[0, 1], [2, 3]])
    }

    @Test func writesOneTrksegPerSegment() throws {
        let track = Self.track([0, 1, 100, 101, 102].map { Self.fix($0) })
        let parsed = try GPXParse(GPXWriter().data(for: track))
        #expect(parsed.count("trk") == 1)
        #expect(parsed.segments.map(\.count) == [2, 3])
    }

    // MARK: Escaping

    @Test func escapesNameAndCreator() throws {
        let name = #"Tom & Jerry's <"race"> ]]> day"#
        let writer = GPXWriter(name: name + "\u{1}\u{FFFE}", creator: "A&B \"tools\"")
        let xml = writer.string(for: Self.track([Self.fix(0)]))
        #expect(xml.contains("<name>Tom &amp; Jerry&apos;s &lt;&quot;race&quot;&gt; ]]&gt; day</name>"))
        #expect(!xml.contains("\u{1}"))

        let parsed = try GPXParse(Data(xml.utf8))
        #expect(parsed.texts("name") == [name, name])
        #expect(parsed.rootAttributes["creator"] == "A&B \"tools\"")
    }

    @Test func escapeKeepsAllowedCharacters() {
        #expect(GPXWriter.escape("Ålesund ⛵️ \t\n") == "Ålesund ⛵️ \t\n")
        #expect(GPXWriter.escape("a\u{0}b\u{B}c\u{1F}d") == "abcd")
    }

    // MARK: Numbers

    @Test func decimalTextIsPlainAndRounded() {
        #expect(DecimalText.fixed(0.000_000_1, digits: 7, trimZeros: true) == "0.0000001")
        #expect(DecimalText.fixed(-0.000_000_01, digits: 7, trimZeros: true) == "0")
        #expect(DecimalText.fixed(-12.345, digits: 2) == "-12.35")
        #expect(DecimalText.fixed(-179.999_999_95, digits: 7, trimZeros: true) == "-180")
        #expect(DecimalText.fixed(2.5, digits: 0) == "3")
        #expect(DecimalText.fixed(1.5, digits: 3) == "1.500")
        #expect(DecimalText.fixed(1.5, digits: 3, trimZeros: true) == "1.5")
        #expect(DecimalText.fixed(1e300, digits: 0).hasPrefix("1000000"))
    }

    @Test func courseIsInZeroTo360() {
        #expect(GPXWriter.courseText(0) == "0")
        #expect(GPXWriter.courseText(359.94) == "359.9")
        #expect(GPXWriter.courseText(359.95) == "0")
        #expect(GPXWriter.courseText(360) == "0")
        #expect(GPXWriter.courseText(725.5) == "5.5")
    }
}

/// A minimal namespace-aware GPX reader built on XMLParser (FoundationXML on Linux).
/// Parsing fails on anything that is not well-formed XML.
private final class GPXParse: NSObject, XMLParserDelegate {
    struct Point { var lat: String; var lon: String }

    var rootName: String?
    var rootNamespace: String?
    var rootAttributes: [String: String] = [:]
    var segments: [[Point]] = []
    private var elements: [(namespace: String?, name: String, text: String)] = []
    private var stack: [Int] = []

    init(_ data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.coderReadCorrupt)
        }
    }

    func count(_ name: String, namespace: String = GPXWriter.gpxNamespace) -> Int {
        elements.filter { $0.name == name && $0.namespace == namespace }.count
    }

    func texts(_ name: String, namespace: String = GPXWriter.gpxNamespace) -> [String] {
        elements.filter { $0.name == name && $0.namespace == namespace }.map(\.text)
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if rootName == nil {
            rootName = elementName
            rootNamespace = namespaceURI
            rootAttributes = attributes
        }
        if elementName == "trkseg" { segments.append([]) }
        if elementName == "trkpt" {
            segments[segments.count - 1].append(Point(lat: attributes["lat"] ?? "", lon: attributes["lon"] ?? ""))
        }
        elements.append((namespaceURI, elementName, ""))
        stack.append(elements.count - 1)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = stack.last { elements[index].text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        stack.removeLast()
    }
}
