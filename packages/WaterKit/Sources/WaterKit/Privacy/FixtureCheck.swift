import Foundation

/// Verifies that a recording is safe to publish: everything on disk matches the
/// anonymized shape `Anonymizer` produces. CI runs it over `fixtures/`.
///
/// Two layers, both required:
/// - **On disk** (`problems(inFolder:)`, `problems(inTrackFile:)`): only known files, only
///   known JSON fields on every line, and no line the reader would skip. Anything the
///   decoder ignores could still hide real data, so it fails here.
/// - **Content** (`problems(in:)`): positions near the fake origin, every timestamp on the
///   anonymized timeline, the synthetic clock anchor, no altitude or magnetic heading, and
///   only allowed event types and data.
public enum FixtureCheck {
    /// Longest plausible session, s. Sample times outside [-slack, end + slack] fail.
    public static let maxDuration = 7 * 86_400.0
    static let timeSlack = 60.0

    // MARK: On disk

    /// Checks a raw recording folder byte for byte, then its decoded content.
    public static func problems(inFolder folder: URL) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let allowedFiles = Set(
            [RawFormat.metaFileName, labelsFileName]
                + RawFormat.Stream.allCases.flatMap { [$0.fileName, $0.gzippedFileName] })
        for name in names.sorted() where !allowedFiles.contains(name) {
            problems.append("unexpected file \(name)")
        }

        if let data = try? Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName)) {
            problems += unknownFields(in: data, allowed: metaFields, context: RawFormat.metaFileName)
        }
        // labels.json is reviewed by people (its description is free text); only its shape is checked.
        if names.contains(labelsFileName),
            let data = try? Data(contentsOf: folder.appendingPathComponent(labelsFileName)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            problems += unknownKeys(Set(object.keys), allowed: labelsFields, context: labelsFileName)
        }
        for stream in RawFormat.Stream.allCases {
            for name in [stream.fileName, stream.gzippedFileName] where names.contains(name) {
                problems += checkLines(
                    of: folder.appendingPathComponent(name), allowed: streamFields[stream] ?? [], context: name)
            }
        }

        do {
            problems += self.problems(in: try RawSessionReader.read(folder: folder))
        } catch {
            problems.append("unreadable: \(error)")
        }
        return problems
    }

    /// Checks a track file's JSON shape, then its decoded content.
    public static func problems(inTrackFile data: Data) -> [String] {
        var problems: [String] = []
        guard let json = try? (Gzip.isGzipped(data) ? Gzip.decompress(data) : data),
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return ["not a readable track file"] }

        problems += unknownKeys(Set(object.keys), allowed: trackFields, context: "track")
        if let gps = object["gps"] as? [String: Any] {
            problems += unknownKeys(Set(gps.keys), allowed: trackGPSColumns, context: "track gps")
        }
        if let hr = object["hr"] as? [String: Any] {
            problems += unknownKeys(Set(hr.keys), allowed: ["t", "bpm"], context: "track hr")
        }
        for case let event as [String: Any] in (object["events"] as? [Any]) ?? [] {
            problems += unknownKeys(Set(event.keys), allowed: ["t", "type", "data"], context: "track event")
        }
        do {
            problems += self.problems(in: try TrackCodec.decode(json))
        } catch {
            problems.append("unreadable: \(error)")
        }
        return Array(Set(problems)).sorted()
    }

    // MARK: Content

    /// Problems found in a decoded raw session; empty when it passes.
    public static func problems(in session: RawSession) -> [String] {
        var problems = common(gps: session.gps, events: session.events, startedAt: session.meta.startedAt)
        let anchor = RawFormat.ClockAnchor(unix: Anonymizer.fakeStart, uptime: Anonymizer.fakeUptime)
        if session.meta.clock != anchor {
            problems.append("meta.json clock is not the synthetic anchor (\(anchor.unix), \(anchor.uptime))")
        }
        if session.clockAnchors.count > 1 {
            problems.append("clock.ndjson has extra anchors; anonymized recordings have only the meta.json anchor")
        }
        var end = session.meta.endedAt.map { $0 - session.meta.startedAt }
        if let value = end, value < 0 || value > maxDuration {
            problems.append("meta.json endedAt is not on the anonymized timeline")
            end = nil  // don't let a bad end widen the window for the samples
        }
        let limit = (end ?? maxDuration) + timeSlack
        let times: [(String, [Double])] = [
            ("gps", session.gps.map(\.t)), ("motion", session.motion.map(\.t)), ("hr", session.hr.map(\.t)),
            ("heading", session.heading.map(\.t)), ("events", session.events.map(\.t)),
        ]
        for (stream, values) in times {
            let outside = values.filter { $0 < -timeSlack || $0 > limit }.count
            if outside > 0 {
                problems.append("\(outside) \(stream) timestamps are not on the anonymized timeline")
            }
        }
        if session.heading.contains(where: { $0.magnetic != nil }) {
            problems.append("heading has magnetic values (with true heading they reveal the declination)")
        }
        if !session.issues.isEmpty {
            problems.append(
                "the reader skipped data, which may still hold real values: "
                    + session.issues.map(\.description).joined(separator: "; "))
        }
        return problems
    }

    /// Problems found in a decoded track; empty when it passes.
    public static func problems(in track: Track) -> [String] {
        var problems = common(gps: track.gps, events: track.events, startedAt: track.startedAt.timeIntervalSince1970)
        if track.summary != nil { problems.append("track has a summary; anonymized tracks drop it") }
        let times = track.gps.map(\.t) + track.hr.map(\.t) + track.events.map(\.t)
        let outside = times.filter { $0 < -timeSlack || $0 > maxDuration }.count
        if outside > 0 { problems.append("\(outside) timestamps are not on the anonymized timeline") }
        return problems
    }

    private static func common(gps: [GPSFix], events: [SessionEvent], startedAt: Double) -> [String] {
        var problems: [String] = []
        if startedAt != Anonymizer.fakeStart {
            problems.append("session starts at Unix time \(startedAt), not the anonymized start (2000-01-01T12:00Z)")
        }
        let far = gps.filter {
            Geo.distance(
                lat1: $0.latitude, lon1: $0.longitude,
                lat2: Anonymizer.fakeOrigin.lat, lon2: Anonymizer.fakeOrigin.lon) > Anonymizer.checkRadius
        }
        if !far.isEmpty {
            problems.append(
                "\(far.count) GPS fixes are more than \(Int(Anonymizer.checkRadius / 1000)) km from the fake origin")
        }
        if gps.contains(where: { $0.altitude != nil || $0.verticalAccuracy != nil }) {
            problems.append("GPS fixes include altitude")
        }
        let badTypes = Set(events.map(\.type).filter { !Anonymizer.allowedEventTypes.contains($0) })
        if !badTypes.isEmpty {
            problems.append("event types not allowed in fixtures: \(badTypes.map(\.rawValue).sorted())")
        }
        let badData = events.filter { event in
            (event.data ?? [:]).contains { key, value in
                !Anonymizer.allowedEventDataKeys.contains(key) || !Anonymizer.isAllowedEventValue(value)
            }
        }
        if !badData.isEmpty {
            problems.append("\(badData.count) events carry data outside the allowed numeric fields")
        }
        return problems
    }

    // MARK: Schema

    static let labelsFileName = "labels.json"
    static let metaFields = Set<String>([
        "format", "version", "sessionId", "sport", "startedAt", "endedAt", "clock", "device", "app",
        "requestedRates", "clock.unix", "clock.uptime", "device.kind", "device.model", "device.os",
        "app.version", "app.build",
    ]).union(RawFormat.Stream.allCases.map { "requestedRates.\($0.rawValue)" })
    static let labelsFields: Set<String> = ["v", "sport", "source", "description", "license", "truth"]
    static let streamFields: [RawFormat.Stream: Set<String>] = [
        .gps: ["ts", "lat", "lon", "alt", "hacc", "vacc", "spd", "spdacc", "crs", "crsacc"],
        .motion: ["ts", "ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw"],
        .hr: ["ts", "bpm"],
        .heading: ["ts", "mag", "true", "acc"],
        .events: ["ts", "type", "data"],
        .clock: ["unix", "uptime"],
    ]
    static let trackFields: Set<String> = [
        "v", "sessionId", "sport", "startedAt", "gps", "hr", "events", "summary", "analyzerVersion",
    ]
    static let trackGPSColumns: Set<String> = ["t", "lat", "lon", "spd", "crs", "hacc", "alt", "spdacc", "crsacc"]

    private static func checkLines(of url: URL, allowed: Set<String>, context: String) -> [String] {
        guard let raw = try? Data(contentsOf: url) else { return ["\(context): unreadable"] }
        let data: Data
        if url.pathExtension == "gz" {
            guard let decoded = try? Gzip.decompress(raw) else { return ["\(context): damaged gzip data"] }
            data = decoded
        } else {
            data = raw
        }
        var unknown = Set<String>()
        var invalid = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                invalid += 1
                continue
            }
            unknown.formUnion(Set(object.keys).subtracting(allowed))
        }
        var problems: [String] = []
        if invalid > 0 { problems.append("\(context): \(invalid) lines are not JSON objects") }
        if !unknown.isEmpty { problems.append("\(context): unknown fields \(unknown.sorted())") }
        return problems
    }

    private static func unknownFields(in data: Data, allowed: Set<String>, context: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["\(context): not a JSON object"]
        }
        var keys = Set(object.keys)
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                keys.formUnion(nested.keys.map { "\(key).\($0)" })
            }
        }
        return unknownKeys(keys, allowed: allowed, context: context)
    }

    private static func unknownKeys(_ keys: Set<String>, allowed: Set<String>, context: String) -> [String] {
        let unknown = keys.subtracting(allowed)
        return unknown.isEmpty ? [] : ["\(context): unknown fields \(unknown.sorted())"]
    }
}
