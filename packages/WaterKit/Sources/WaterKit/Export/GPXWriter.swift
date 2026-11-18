import Foundation

/// Writes a `Track` as GPX 1.1 for other apps (Strava, OpenCPN, mapping tools).
///
/// GPX is an export, not a storage format: it carries only the GPS track. The output is
/// specified in docs/formats.md ("GPX export"):
///
/// - One `<trk>` named for the sport, with the sport's wire name as `<type>`.
/// - Fixes in time order. Fixes with a non-finite time or invalid coordinates are skipped.
/// - `<ele>` when the fix has an altitude; `<time>` is `startedAt + t` in ISO 8601 UTC.
/// - Doppler speed (m/s) and course (degrees true) in a Garmin TrackPointExtension v2 block.
/// - A new `<trkseg>` after each pause→resume pair and after any gap between fixes longer
///   than `segmentGap`.
public struct GPXWriter: Sendable {
    public static let gpxNamespace = "http://www.topografix.com/GPX/1/1"
    public static let gpxSchemaLocation = "http://www.topografix.com/GPX/1/1/gpx.xsd"
    /// Garmin's TrackPointExtension v2, which most GPX readers understand.
    public static let trackPointExtensionNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
    public static let trackPointExtensionSchemaLocation = "http://www.garmin.com/xmlschemas/TrackPointExtensionv2.xsd"
    /// Default `segmentGap`, s. Longer than any normal GPS dropout at 1 Hz, short enough
    /// that a signal loss (watch under water, phone in a dry bag) is not drawn as a
    /// straight line across the chart.
    public static let defaultSegmentGap: Double = 30

    /// A gap between consecutive fixes longer than this, s, starts a new segment.
    public var segmentGap: Double
    /// Name for the track and metadata. Nil uses the sport's name ("Sailing", "Kayak", ...).
    public var name: String?
    /// The GPX `creator` attribute.
    public var creator: String

    public init(segmentGap: Double = GPXWriter.defaultSegmentGap, name: String? = nil, creator: String = "MadeGood") {
        self.segmentGap = segmentGap
        self.name = name
        self.creator = creator
    }

    /// The GPX document as UTF-8 data.
    public func data(for track: Track) -> Data {
        Data(string(for: track).utf8)
    }

    /// The selected GPX document, with the retained fixes' original timestamps.
    public func data(for selection: SessionSelection) -> Data {
        Data(string(for: selection.track, originalClock: selection.originalGPSClock).utf8)
    }

    /// The GPX document.
    public func string(for track: Track) -> String {
        string(for: track, originalClock: nil)
    }

    private func string(for track: Track, originalClock: SessionSelection.OriginalGPSClock?) -> String {
        let name = Self.escape(name ?? Self.displayName(track.sport))
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="\(Self.escape(creator))" \
            xmlns="\(Self.gpxNamespace)" \
            xmlns:gpxtpx="\(Self.trackPointExtensionNamespace)" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
            xsi:schemaLocation="\(Self.gpxNamespace) \(Self.gpxSchemaLocation) \
            \(Self.trackPointExtensionNamespace) \(Self.trackPointExtensionSchemaLocation)">
              <metadata>
                <name>\(name)</name>
                <time>\(Timestamp.format(track.startedAt))</time>
              </metadata>
              <trk>
                <name>\(name)</name>
                <type>\(Self.escape(track.sport.rawValue))</type>

            """
        for segment in indexedSegments(of: track) {
            xml += "    <trkseg>\n"
            for (offset, fix) in segment {
                let date =
                    originalClock.map { $0.startedAt.addingTimeInterval($0.times[offset]) }
                    ?? track.startedAt.addingTimeInterval(fix.t)
                xml += "      "
                xml += Self.trackPoint(fix, at: date)
                xml += "\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    /// The exportable fixes in time order, split into segments as described above.
    /// Fixes with equal times keep their stored order.
    public func segments(of track: Track) -> [[GPSFix]] {
        indexedSegments(of: track).map { $0.map(\.element) }
    }

    private func indexedSegments(of track: Track) -> [[(offset: Int, element: GPSFix)]] {
        let fixes = track.gps.enumerated()
            .filter { Self.isExportable($0.element) }
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
        let resumes = Self.resumeTimes(track.events)

        var segments: [[(offset: Int, element: GPSFix)]] = []
        var current: [(offset: Int, element: GPSFix)] = []
        var nextResume = 0
        for indexed in fixes {
            let fix = indexed.element
            if let last = current.last?.element {
                while nextResume < resumes.count && resumes[nextResume] <= last.t { nextResume += 1 }
                let resumedBetween = nextResume < resumes.count && resumes[nextResume] <= fix.t
                if resumedBetween || fix.t - last.t > segmentGap {
                    segments.append(current)
                    current = []
                }
            }
            current.append(indexed)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    // MARK: Helpers

    static func isExportable(_ fix: GPSFix) -> Bool {
        fix.t.isFinite && fix.latitude.isFinite && fix.longitude.isFinite
            && (-90...90).contains(fix.latitude) && (-180...180).contains(fix.longitude)
    }

    /// Times of `resume` events that follow a `pause`, sorted. A resume without an
    /// earlier pause, or a pause that is never resumed, splits nothing.
    static func resumeTimes(_ events: [SessionEvent]) -> [Double] {
        let ordered = events.enumerated()
            .filter { $0.element.t.isFinite }
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
            .map(\.element)
        var paused = false
        var times: [Double] = []
        for event in ordered {
            if event.type == .pause {
                paused = true
            } else if event.type == .resume && paused {
                paused = false
                times.append(event.t)
            }
        }
        return times
    }

    /// GPX 1.1 longitude is in [-180, 180): the antimeridian, including values that round
    /// to it, is written as -180.
    static func longitudeText(_ longitude: Double) -> String {
        let text = DecimalText.fixed(longitude, digits: 7, trimZeros: true)
        return text == "180" ? "-180" : text
    }

    static func trackPoint(_ fix: GPSFix, at date: Date) -> String {
        var point = "<trkpt lat=\"\(DecimalText.fixed(fix.latitude, digits: 7, trimZeros: true))\""
        point += " lon=\"\(longitudeText(fix.longitude))\">"
        if let altitude = fix.altitude, altitude.isFinite {
            point += "<ele>\(DecimalText.fixed(altitude, digits: 1, trimZeros: true))</ele>"
        }
        point += "<time>\(Timestamp.format(date))</time>"

        var fields = ""
        if let speed = fix.speed, speed.isFinite, speed >= 0 {
            fields += "<gpxtpx:speed>\(DecimalText.fixed(speed, digits: 2, trimZeros: true))</gpxtpx:speed>"
        }
        if let course = fix.course, course.isFinite, course >= 0 {
            fields += "<gpxtpx:course>\(courseText(course))</gpxtpx:course>"
        }
        if !fields.isEmpty {
            point += "<extensions><gpxtpx:TrackPointExtension>\(fields)</gpxtpx:TrackPointExtension></extensions>"
        }
        return point + "</trkpt>"
    }

    /// Course rounded to 0.1° in [0, 360), as the extension's schema requires.
    static func courseText(_ course: Double) -> String {
        let rounded = (course.truncatingRemainder(dividingBy: 360) * 10).rounded(.toNearestOrAwayFromZero) / 10
        return DecimalText.fixed(rounded >= 360 ? 0 : rounded, digits: 1, trimZeros: true)
    }

    static func displayName(_ sport: Sport) -> String {
        switch sport {
        case .sailing: "Sailing"
        case .windsurfing: "Windsurfing"
        case .motorboating: "Motorboating"
        case .kayak: "Kayak"
        case .canoe: "Canoe"
        case .sup: "Stand-up paddle"
        }
    }

    /// Escapes text for XML element content or a quoted attribute value. Characters
    /// XML 1.0 does not allow (most C0 controls, U+FFFE, U+FFFF) are dropped.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                switch scalar.value {
                case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                    escaped.unicodeScalars.append(scalar)
                default:
                    continue
                }
            }
        }
        return escaped
    }
}
