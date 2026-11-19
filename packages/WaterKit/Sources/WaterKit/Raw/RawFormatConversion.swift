import Foundation

/// Converts a recording folder to the current raw format version, file by file, for
/// exports of recordings made before version 2: no file then holds a device-uptime reading.
///
/// Only what version 2 changed is rewritten: `meta.json` loses `clock` and gets the new
/// version, motion and clock lines move from device uptime to the session's monotonic
/// clock (`mono = clock.unix + (uptime − clock.uptime)`). Every wall-clock stream is copied
/// byte for byte, so event order and every value stay exactly as recorded. Motion and
/// clock lines that do not parse are left out, as the reader would skip them. Other files
/// in the folder (the derived track) are copied unchanged.
public enum RawFormatConversion {
    /// Writes the converted recording into `destination` (created if needed). Returns false,
    /// writing nothing, when `folder` is already the current version.
    @discardableResult
    public static func convertToCurrent(folder: URL, into destination: URL) throws -> Bool {
        let (_, legacy) = try RawSessionReader.readMetaAndLegacyClock(folder: folder)
        guard let legacy else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let toMono = { (uptime: Double) in legacy.unix + (uptime - legacy.uptime) }

        let metaData = try Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName))
        guard var object = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            throw RawSessionReader.Error.invalidMeta("not an object")
        }
        object["clock"] = nil
        object["version"] = RawFormat.version
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: destination.appendingPathComponent(RawFormat.metaFileName))

        for name in try fm.contentsOfDirectory(atPath: folder.path) where name != RawFormat.metaFileName {
            let source = folder.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let stream = RawFormat.Stream.allCases.first { name == $0.fileName || name == $0.gzippedFileName }
            switch stream {
            case .motion:
                let lines: [RawFormat.MotionLine] = try readLines(source, name: name)
                try write(
                    lines.map { line in
                        var converted = line
                        converted.ts = toMono(line.ts)
                        return converted
                    }, to: target, gzip: name.hasSuffix(".gz"))
            case .clock:
                let lines: [RawFormat.V1.ClockAnchor] = try readLines(source, name: name)
                try write(
                    lines.map { RawFormat.ClockAnchor(unix: $0.unix, mono: toMono($0.uptime)) }, to: target,
                    gzip: name.hasSuffix(".gz"))
            default:
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
            }
        }
        return true
    }

    private static func readLines<Line: Decodable>(_ url: URL, name: String) throws -> [Line] {
        var data = try Data(contentsOf: url)
        if name.hasSuffix(".gz") {
            guard !data.isEmpty else { return [] }
            data = (try? Gzip.decompressAvailable(data))?.data ?? Data()
        }
        var issues: [RawReadIssue] = []
        return NDJSON.decode(Line.self, from: data, file: name, issues: &issues)
    }

    private static func write<Line: Encodable>(_ lines: [Line], to url: URL, gzip: Bool) throws {
        var data = Data()
        for line in lines { data.append(try RawFormat.line(line)) }
        try (gzip ? Gzip.compress(data) : data).write(to: url)
    }
}
