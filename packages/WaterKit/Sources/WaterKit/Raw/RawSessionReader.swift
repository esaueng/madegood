import Foundation

/// Reads a raw recording folder (docs/formats.md). Missing streams are treated as
/// empty. Damaged lines and truncated gzip files become `RawSession.issues` rather than
/// errors, so a recording cut short by a crash or a dead battery still opens.
public enum RawSessionReader {
    public struct FileRevision: Hashable, Sendable {
        let name: String
        let size: Int64?
        let modifiedAt: Date?
        let fileNumber: UInt64?
    }

    public static func isRecordingFileName(_ name: String) -> Bool {
        name == RawFormat.metaFileName
            || RawFormat.Stream.allCases.contains { name == $0.fileName || name == $0.gzippedFileName }
    }

    /// A cheap cache identity for the raw inputs, excluding derived track files.
    /// Track each file individually because replacement need not change its size.
    public static func revision(of folder: URL) -> [FileRevision] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isRecordingFileName).sorted()
        return files.map { name in
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return FileRevision(
                name: name, size: (attributes?[.size] as? NSNumber)?.int64Value,
                modifiedAt: attributes?[.modificationDate] as? Date,
                fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingMeta(URL)
        case invalidMeta(String)
        case unsupportedFormat(String)
        case unsupportedVersion(Int)
        case bothPlainAndGzipped(String)

        public var description: String {
            switch self {
            case .missingMeta(let url): "No \(RawFormat.metaFileName) in \(url.path)"
            case .invalidMeta(let reason): "Invalid \(RawFormat.metaFileName): \(reason)"
            case .unsupportedFormat(let name): "Not a MadeGood raw recording (format \"\(name)\")"
            case .unsupportedVersion(let v):
                "Unsupported raw format version \(v); this reader supports \(RawFormat.version)"
            case .bothPlainAndGzipped(let stream):
                "Both \(stream).ndjson and \(stream).ndjson.gz exist; remove one"
            }
        }
    }

    /// Reads a recording folder. Pass `includeMotion: false` to skip the 100 Hz motion
    /// stream (tens of MB per hour) when only GPS, heart rate and events are needed.
    public static func read(folder: URL, includeMotion: Bool = true) throws -> RawSession {
        let meta = try readMeta(folder: folder)
        var issues: [RawReadIssue] = []

        let clockLines: [RawFormat.ClockAnchor] = try readStream(.clock, in: folder, issues: &issues)
        let anchors = ([meta.clock] + clockLines).sorted { $0.uptime < $1.uptime }
        let clock = SessionClock(startedAt: meta.startedAt, anchors: anchors)

        let gps = try (readStream(.gps, in: folder, issues: &issues) as [RawFormat.GPSLine]).map { line in
            GPSFix(
                t: clock.fromUnix(line.ts), latitude: line.lat, longitude: line.lon, altitude: line.alt,
                horizontalAccuracy: line.hacc, verticalAccuracy: line.vacc, speed: line.spd,
                speedAccuracy: line.spdacc, course: line.crs, courseAccuracy: line.crsacc)
        }
        let motionLines: [RawFormat.MotionLine] =
            includeMotion ? try readStream(.motion, in: folder, issues: &issues) : []
        let motion = motionLines.map { l in
            MotionSample(
                t: clock.fromUptime(l.ts),
                userAcceleration: Vector3(x: l.ax, y: l.ay, z: l.az),
                gravity: Vector3(x: l.gx, y: l.gy, z: l.gz),
                rotationRate: Vector3(x: l.rx, y: l.ry, z: l.rz),
                attitude: Quaternion(x: l.qx, y: l.qy, z: l.qz, w: l.qw))
        }
        let hr = try (readStream(.hr, in: folder, issues: &issues) as [RawFormat.HRLine]).map {
            HRSample(t: clock.fromUnix($0.ts), bpm: $0.bpm)
        }
        let heading = try (readStream(.heading, in: folder, issues: &issues) as [RawFormat.HeadingLine]).map {
            HeadingSample(t: clock.fromUnix($0.ts), magnetic: $0.mag, trueHeading: $0.trueHeading, accuracy: $0.acc)
        }
        let events = try (readStream(.events, in: folder, issues: &issues) as [RawFormat.EventLine]).map {
            SessionEvent(t: clock.fromUnix($0.ts), type: EventType($0.type), data: $0.data)
        }

        return RawSession(
            meta: meta,
            gps: sortedByTime(gps, \.t),
            motion: sortedByTime(motion, \.t),
            hr: sortedByTime(hr, \.t),
            heading: sortedByTime(heading, \.t),
            events: sortedByTime(events, \.t),
            clockAnchors: anchors,
            issues: issues)
    }

    public static func readMeta(folder: URL) throws -> RawFormat.Meta {
        let url = folder.appendingPathComponent(RawFormat.metaFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.missingMeta(folder) }
        let data = try Data(contentsOf: url)

        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw Error.invalidMeta(String(describing: error))
        }
        guard header.format == RawFormat.formatName else { throw Error.unsupportedFormat(header.format ?? "none") }
        guard header.version == RawFormat.version else { throw Error.unsupportedVersion(header.version ?? 0) }
        do {
            return try JSONDecoder().decode(RawFormat.Meta.self, from: data)
        } catch {
            throw Error.invalidMeta(String(describing: error))
        }
    }

    // MARK: Streams

    private static func readStream<Line: Decodable>(
        _ stream: RawFormat.Stream, in folder: URL, issues: inout [RawReadIssue]
    ) throws -> [Line] {
        let plain = folder.appendingPathComponent(stream.fileName)
        let gzipped = folder.appendingPathComponent(stream.gzippedFileName)
        let fm = FileManager.default
        let hasPlain = fm.fileExists(atPath: plain.path)
        let hasGzipped = fm.fileExists(atPath: gzipped.path)
        if hasPlain && hasGzipped { throw Error.bothPlainAndGzipped(stream.rawValue) }

        let data: Data
        let fileName: String
        if hasGzipped {
            fileName = stream.gzippedFileName
            let raw = try Data(contentsOf: gzipped)
            if raw.isEmpty { return [] }
            do {
                let result = try Gzip.decompressAvailable(raw)
                if !result.complete { issues.append(RawReadIssue(file: fileName, line: nil, kind: .truncatedFile)) }
                data = result.data
            } catch {
                // A damaged stream must not stop the other streams from opening.
                issues.append(RawReadIssue(file: fileName, line: nil, kind: .unreadableFile(String(describing: error))))
                return []
            }
        } else if hasPlain {
            fileName = stream.fileName
            data = try Data(contentsOf: plain)
        } else {
            return []
        }
        return NDJSON.decode(Line.self, from: data, file: fileName, issues: &issues)
    }

    private static func sortedByTime<T>(_ items: [T], _ time: (T) -> Double) -> [T] {
        // Stable: equal times keep file order.
        items.enumerated()
            .sorted {
                time($0.element) != time($1.element) ? time($0.element) < time($1.element) : $0.offset < $1.offset
            }
            .map(\.element)
    }
}

/// Maps sensor clocks onto session time.
struct SessionClock: Sendable {
    var startedAt: Double
    /// Sorted by uptime; never empty.
    var anchors: [RawFormat.ClockAnchor]

    func fromUnix(_ unix: Double) -> Double { unix - startedAt }

    /// Converts device uptime using the latest anchor at or before it (or the first anchor),
    /// so wall-clock corrections during a session apply from the moment they were recorded.
    func fromUptime(_ uptime: Double) -> Double {
        var anchor = anchors[0]
        var low = 0
        var high = anchors.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if anchors[mid].uptime <= uptime {
                anchor = anchors[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Subtract the large values first so sub-millisecond offsets keep full precision.
        return (anchor.unix - startedAt) + (uptime - anchor.uptime)
    }
}

/// Newline-delimited JSON decoding that tolerates damage.
enum NDJSON {
    static func decode<Line: Decodable>(
        _ type: Line.Type, from data: Data, file: String, issues: inout [RawReadIssue]
    ) -> [Line] {
        let decoder = JSONDecoder()
        var lines: [Line] = []
        let bytes = [UInt8](data)
        let endsWithNewline = bytes.last == 0x0A
        var lineNumber = 0
        var start = 0
        while start < bytes.count {
            lineNumber += 1
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            var slice = bytes[start..<end]
            if slice.last == 0x0D { slice = slice.dropLast() }
            let isLastLine = end >= bytes.count - (endsWithNewline ? 1 : 0)
            start = end + 1

            if slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            do {
                lines.append(try decoder.decode(Line.self, from: Data(slice)))
            } catch {
                if isLastLine && !endsWithNewline {
                    issues.append(RawReadIssue(file: file, line: lineNumber, kind: .truncatedLine))
                } else {
                    issues.append(RawReadIssue(file: file, line: lineNumber, kind: .invalidLine(reason(error))))
                }
            }
        }
        return lines
    }

    private static func reason(_ error: any Swift.Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "bad value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted: "not valid JSON"
        default: String(describing: error)
        }
    }
}
