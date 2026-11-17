import Foundation

/// Reads and writes track v1: column-oriented JSON, usually gzipped (`track.json.gz`).
/// The format is specified in docs/formats.md.
public enum TrackCodec {
    public static let version = 1

    public enum Error: Swift.Error, Equatable {
        case unsupportedVersion(Int)
        case invalidSessionId(String)
        case unknownSport(String)
        case invalidDate(String)
        case columnLengthMismatch(stream: String, column: String, expected: Int, actual: Int)
        case nonFiniteValue(stream: String, column: String)
    }

    // MARK: Encoding

    /// Encodes `track` as gzipped track v1 JSON.
    public static func encode(_ track: Track) throws -> Data {
        try Gzip.compress(encodeJSON(track))
    }

    /// Encodes `track` as uncompressed track v1 JSON. Values are rounded to the
    /// precision documented in docs/formats.md.
    public static func encodeJSON(_ track: Track) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(try Wire(track))
    }

    // MARK: Decoding

    /// Decodes track v1 from gzipped or plain JSON.
    public static func decode(_ data: Data) throws -> Track {
        let json = Gzip.isGzipped(data) ? try Gzip.decompress(data) : data
        let decoder = JSONDecoder()
        let header = try decoder.decode(VersionHeader.self, from: json)
        guard header.v == version else { throw Error.unsupportedVersion(header.v) }
        return try decoder.decode(Wire.self, from: json).track()
    }

    // MARK: Wire format

    private struct VersionHeader: Decodable {
        var v: Int
    }

    private struct Wire: Codable {
        var v: Int
        var sessionId: String
        var sport: String
        var startedAt: String
        var gps: GPSColumns
        var hr: HRColumns
        var events: [EventWire]
        var summary: JSONValue?
        var analyzerVersion: String?

        init(_ track: Track) throws {
            v = TrackCodec.version
            sessionId = track.sessionId.uuidString.lowercased()
            sport = track.sport.rawValue
            startedAt = Timestamp.format(track.startedAt)
            gps = try GPSColumns(track.gps)
            hr = try HRColumns(track.hr)
            events = try track.events.map(EventWire.init)
            summary = track.summary
            analyzerVersion = track.analyzerVersion
        }

        func track() throws -> Track {
            guard let id = UUID(uuidString: sessionId) else { throw Error.invalidSessionId(sessionId) }
            guard let sport = Sport(rawValue: sport) else { throw Error.unknownSport(sport) }
            guard let started = Timestamp.parse(startedAt) else { throw Error.invalidDate(startedAt) }
            return Track(
                sessionId: id, sport: sport, startedAt: started, gps: try gps.fixes(), hr: try hr.samples(),
                events: events.map(\.event), summary: summary, analyzerVersion: analyzerVersion)
        }
    }

    private struct GPSColumns: Codable {
        var t: [Double]
        var lat: [Double]
        var lon: [Double]
        var spd: [Double?]
        var crs: [Double?]
        var hacc: [Double?]
        var alt: [Double?]?
        var spdacc: [Double?]?
        var crsacc: [Double?]?

        init(_ fixes: [GPSFix]) throws {
            t = try fixes.map { try finite($0.t, "gps", "t").rounded(to: 1e-3) }
            lat = try fixes.map { try finite($0.latitude, "gps", "lat").rounded(to: 1e-7) }
            lon = try fixes.map { try finite($0.longitude, "gps", "lon").rounded(to: 1e-7) }
            spd = try fixes.map { try finiteOrNil($0.speed, "gps", "spd")?.rounded(to: 1e-2) }
            crs = try fixes.map { try finiteOrNil($0.course, "gps", "crs")?.rounded(to: 1e-1) }
            hacc = try fixes.map { try finiteOrNil($0.horizontalAccuracy, "gps", "hacc")?.rounded(to: 1e-1) }
            alt = try optionalColumn(fixes.map(\.altitude), "alt", step: 1e-1)
            spdacc = try optionalColumn(fixes.map(\.speedAccuracy), "spdacc", step: 1e-2)
            crsacc = try optionalColumn(fixes.map(\.courseAccuracy), "crsacc", step: 1e-1)
        }

        func fixes() throws -> [GPSFix] {
            let n = t.count
            try checkLength("gps", "lat", n, lat.count)
            try checkLength("gps", "lon", n, lon.count)
            try checkLength("gps", "spd", n, spd.count)
            try checkLength("gps", "crs", n, crs.count)
            try checkLength("gps", "hacc", n, hacc.count)
            if let alt { try checkLength("gps", "alt", n, alt.count) }
            if let spdacc { try checkLength("gps", "spdacc", n, spdacc.count) }
            if let crsacc { try checkLength("gps", "crsacc", n, crsacc.count) }
            return (0..<n).map { i in
                GPSFix(
                    t: t[i], latitude: lat[i], longitude: lon[i], altitude: alt?[i],
                    horizontalAccuracy: hacc[i], speed: spd[i], speedAccuracy: spdacc?[i],
                    course: crs[i], courseAccuracy: crsacc?[i])
            }
        }

        private func optionalColumn(_ values: [Double?], _ name: String, step: Double) throws -> [Double?]? {
            guard values.contains(where: { $0 != nil }) else { return nil }
            return try values.map { try finiteOrNil($0, "gps", name)?.rounded(to: step) }
        }
    }

    private struct HRColumns: Codable {
        var t: [Double]
        var bpm: [Double]

        init(_ samples: [HRSample]) throws {
            t = try samples.map { try finite($0.t, "hr", "t").rounded(to: 1e-3) }
            bpm = try samples.map { try finite($0.bpm, "hr", "bpm").rounded(to: 1e-1) }
        }

        func samples() throws -> [HRSample] {
            try checkLength("hr", "bpm", t.count, bpm.count)
            return zip(t, bpm).map { HRSample(t: $0, bpm: $1) }
        }
    }

    private struct EventWire: Codable {
        var t: Double
        var type: String
        var data: [String: JSONValue]?

        init(_ event: SessionEvent) throws {
            t = try finite(event.t, "events", "t").rounded(to: 1e-3)
            type = event.type.rawValue
            data = event.data
        }

        var event: SessionEvent { SessionEvent(t: t, type: EventType(type), data: data) }
    }

    private static func checkLength(_ stream: String, _ column: String, _ expected: Int, _ actual: Int) throws {
        guard expected == actual else {
            throw Error.columnLengthMismatch(stream: stream, column: column, expected: expected, actual: actual)
        }
    }

    private static func finite(_ value: Double, _ stream: String, _ column: String) throws -> Double {
        guard value.isFinite else { throw Error.nonFiniteValue(stream: stream, column: column) }
        return value
    }

    private static func finiteOrNil(_ value: Double?, _ stream: String, _ column: String) throws -> Double? {
        guard let value else { return nil }
        return try finite(value, stream, column)
    }
}

extension Double {
    /// Rounds to the nearest multiple of `step`, a negative power of ten such as 1e-3.
    /// Dividing by the exact scale (rather than multiplying by `step`) yields the double
    /// closest to the decimal value, so JSON output stays short.
    func rounded(to step: Double) -> Double {
        let scale = (1 / step).rounded()
        return (self * scale).rounded() / scale
    }
}
