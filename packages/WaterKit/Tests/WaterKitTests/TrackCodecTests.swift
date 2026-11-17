import Foundation
import Testing

@testable import WaterKit

@Suite struct TrackCodecTests {
    static let start = Date(timeIntervalSince1970: 1_809_165_600.25)  // 2027-05-01T10:00:00.250Z

    static func sampleTrack() -> Track {
        Track(
            sessionId: UUID(uuidString: "6F1C2A3E-8A5B-4C1D-9E2F-0A1B2C3D4E5F")!,
            sport: .kayak,
            startedAt: start,
            gps: [
                GPSFix(
                    t: 0, latitude: 0.000_123_456_78, longitude: -0.000_2, horizontalAccuracy: 4.04, speed: 1.234,
                    course: 359.96),
                GPSFix(
                    t: 1.000_4, latitude: 0.000_13, longitude: -0.000_21, altitude: 1.26, horizontalAccuracy: nil,
                    speed: nil, speedAccuracy: 0.3, course: nil),
            ],
            hr: [HRSample(t: 0.5, bpm: 101), HRSample(t: 1.5, bpm: 102.44)],
            events: [
                SessionEvent(t: 0.9, type: .mark),
                SessionEvent(t: 1.2, type: .tack, data: ["durationS": 8.1, "note": "port"]),
            ],
            summary: ["strokes": 0],
            analyzerVersion: "0.0.1")
    }

    @Test func roundTripsThroughGzip() throws {
        let track = Self.sampleTrack()
        let decoded = try TrackCodec.decode(TrackCodec.encode(track))

        #expect(decoded.sessionId == track.sessionId)
        #expect(decoded.sport == .kayak)
        #expect(abs(decoded.startedAt.timeIntervalSince(track.startedAt)) < 0.001)
        #expect(decoded.gps.count == 2)
        #expect(decoded.gps[0].latitude == 0.000_123_5)  // rounded to 1e-7
        #expect(decoded.gps[0].speed == 1.23)
        #expect(decoded.gps[0].course == 360.0)
        #expect(decoded.gps[1].t == 1.0)
        #expect(decoded.gps[1].speed == nil)
        #expect(decoded.gps[1].horizontalAccuracy == nil)
        #expect(decoded.gps[1].altitude == 1.3)
        #expect(decoded.gps[1].speedAccuracy == 0.3)
        #expect(decoded.hr.map(\.bpm) == [101, 102.4])
        #expect(decoded.events == track.events)
        #expect(decoded.summary == track.summary)
        #expect(decoded.analyzerVersion == "0.0.1")
    }

    @Test func writesTheDocumentedShape() throws {
        let json = try TrackCodec.encodeJSON(Self.sampleTrack())
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["sessionId"] as? String == "6f1c2a3e-8a5b-4c1d-9e2f-0a1b2c3d4e5f")
        #expect(object["sport"] as? String == "kayak")
        #expect(object["startedAt"] as? String == "2027-05-01T10:00:00.250Z")
        let gps = try #require(object["gps"] as? [String: Any])
        #expect(Set(gps.keys) == ["t", "lat", "lon", "spd", "crs", "hacc", "alt", "spdacc"])
        let hr = try #require(object["hr"] as? [String: Any])
        #expect(Set(hr.keys) == ["t", "bpm"])
        // Rounded values print in short decimal form.
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"lat\":[0.0001235,0.00013]"))
    }

    @Test func omitsOptionalColumnsWhenEmpty() throws {
        var track = Self.sampleTrack()
        track.gps = [GPSFix(t: 0, latitude: 0, longitude: 0)]
        let object = try JSONSerialization.jsonObject(with: TrackCodec.encodeJSON(track)) as? [String: Any]
        let gps = try #require(object?["gps"] as? [String: Any])
        #expect(Set(gps.keys) == ["t", "lat", "lon", "spd", "crs", "hacc"])
    }

    @Test func decodesHandWrittenExample() throws {
        let track = try TrackCodec.decode(Fixtures.data("track-v1-example.json"))
        #expect(track.sport == .sailing)
        #expect(track.startedAt == Date(timeIntervalSince1970: 1_809_165_600))
        #expect(track.gps.map(\.speed) == [2.5, 2.6, nil])
        #expect(track.hr.count == 2)
        #expect(track.events.map(\.type) == [.tack, .lap, .mob])
        #expect(track.events[0].data?["durationS"] == 8.1)
        #expect(track.duration == 2)
    }

    @Test func rejectsOtherVersions() throws {
        let json = Data(#"{"v":2,"whatever":true}"#.utf8)
        #expect(throws: TrackCodec.Error.unsupportedVersion(2)) { try TrackCodec.decode(json) }
    }

    @Test func rejectsMismatchedColumns() throws {
        var text = String(decoding: try Fixtures.data("track-v1-example.json"), as: UTF8.self)
        text = text.replacingOccurrences(of: #""lon": [0.0002, 0.0002, 0.0002]"#, with: #""lon": [0.0002]"#)
        #expect(throws: TrackCodec.Error.columnLengthMismatch(stream: "gps", column: "lon", expected: 3, actual: 1)) {
            try TrackCodec.decode(Data(text.utf8))
        }
    }

    @Test func rejectsUnknownSport() throws {
        var text = String(decoding: try Fixtures.data("track-v1-example.json"), as: UTF8.self)
        text = text.replacingOccurrences(of: #""sport": "sailing""#, with: #""sport": "rowing""#)
        #expect(throws: TrackCodec.Error.unknownSport("rowing")) { try TrackCodec.decode(Data(text.utf8)) }
    }

    @Test func rejectsNonFiniteValues() {
        var track = Self.sampleTrack()
        track.gps[0].speed = .nan
        #expect(throws: TrackCodec.Error.nonFiniteValue(stream: "gps", column: "spd")) {
            try TrackCodec.encode(track)
        }
    }

    @Test func roundingKeepsShortDecimals() {
        #expect(37.123_456_789.rounded(to: 1e-7) == 37.123_456_8)
        #expect(0.1.rounded(to: 1e-3) == 0.1)
        #expect("\(0.3.rounded(to: 1e-2))" == "0.3")
    }
}
