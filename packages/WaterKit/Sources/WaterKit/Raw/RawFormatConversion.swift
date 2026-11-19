import Foundation

/// Converts a recording folder to the current raw format version, file by file, for
/// exports of recordings made before version 2: no file then holds a device-uptime reading.
///
/// Only the files of a recording are written (`RawSessionReader.isRecordingFileName`):
/// staging files of an interrupted watch transfer (`.incoming-…`), the derived track and
/// anything else in the folder are left out. Only what version 2 changed is rewritten:
/// `meta.json` loses `clock` and gets the new version, motion and clock lines move from
/// device uptime to the session's monotonic clock (`mono = clock.unix + (uptime − clock.uptime)`).
/// Every wall-clock stream is copied byte for byte, so event order and every value stay as
/// recorded. Motion and clock lines are converted as a stream, line by line through gzip in
/// and out, so a long recording is never held in memory; lines that do not parse are left
/// out, as the reader would skip them, and a truncated last gzip member is read up to where
/// it ends.
public enum RawFormatConversion {
    /// Bytes read per chunk while converting.
    static let chunkSize = 1 << 20

    /// Writes the converted recording into `destination` (created if needed). Returns false,
    /// writing nothing, when `folder` is already the current version.
    @discardableResult
    public static func convertToCurrent(
        folder: URL, into destination: URL, progress: @escaping (Double) -> Void = { _ in }
    ) throws -> Bool {
        let (_, legacy) = try RawSessionReader.readMetaAndLegacyClock(folder: folder)
        guard legacy != nil else { return false }
        try exportCopy(folder: folder, into: destination, progress: progress)
        return true
    }

    /// The recording in `folder`, in the current version and with only its own files, in
    /// `destination`: what sharing a raw recording sends. A current-version recording is
    /// copied; a version 1 recording is converted. `progress` goes from 0 to 1.
    public static func exportCopy(
        folder: URL, into destination: URL, progress: @escaping (Double) -> Void = { _ in }
    ) throws {
        let (_, legacy) = try RawSessionReader.readMetaAndLegacyClock(folder: folder)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = try fm.contentsOfDirectory(atPath: folder.path)
            .filter(RawSessionReader.isRecordingFileName).sorted()
        let sizes = names.map { name in
            ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size] as? NSNumber)?
                .int64Value ?? 0
        }
        let total = max(1, sizes.reduce(0, +))
        var done: Int64 = 0
        progress(0)

        for (name, size) in zip(names, sizes) {
            let source = folder.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let report: (Int64) -> Void = { read in progress(Double(done + read) / Double(total)) }
            let stream = RawFormat.Stream.allCases.first { name == $0.fileName || name == $0.gzippedFileName }
            if let legacy, name == RawFormat.metaFileName {
                let metaData = try Data(contentsOf: source)
                guard var object = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
                    throw RawSessionReader.Error.invalidMeta("not an object")
                }
                object["clock"] = nil
                object["version"] = RawFormat.version
                try JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ).write(to: target)
            } else if let legacy, stream == .motion {
                let toMono = { (uptime: Double) in legacy.unix + (uptime - legacy.uptime) }
                try convertLines(from: source, to: target, gzip: name.hasSuffix(".gz"), progress: report) {
                    (line: RawFormat.MotionLine) in
                    var converted = line
                    converted.ts = toMono(line.ts)
                    return converted
                }
            } else if let legacy, stream == .clock {
                let toMono = { (uptime: Double) in legacy.unix + (uptime - legacy.uptime) }
                try convertLines(from: source, to: target, gzip: name.hasSuffix(".gz"), progress: report) {
                    (line: RawFormat.V1.ClockAnchor) in RawFormat.ClockAnchor(unix: line.unix, mono: toMono(line.uptime))
                }
            } else {
                try fm.copyItem(at: source, to: target)
            }
            done += size
            progress(Double(done) / Double(total))
        }
    }

    /// Streams `source` line by line through `transform` into `target`, each optionally
    /// gzipped, reading `chunkSize` bytes at a time. Damaged lines are skipped.
    static func convertLines<In: Decodable, Out: Encodable>(
        from source: URL, to target: URL, gzip: Bool, chunk: Int = chunkSize,
        progress: @escaping (Int64) -> Void = { _ in }, transform: (In) -> Out
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        let writer = gzip ? try Gzip.Writer { try output.write(contentsOf: $0) } : nil
        let put: (Data) throws -> Void = { data in
            if let writer { try writer.write(data) } else { try output.write(contentsOf: data) }
        }

        let decoder = JSONDecoder()
        var carry = Data()
        func lines(_ chunk: Data, final: Bool) throws {
            carry.append(chunk)
            var start = carry.startIndex
            while let end = carry[start...].firstIndex(of: 0x0A) {
                try convert(carry[start..<end])
                start = carry.index(after: end)
            }
            carry.removeSubrange(carry.startIndex..<start)
            if final, !carry.isEmpty {
                try convert(carry[...])
                carry.removeAll()
            }
        }
        func convert(_ line: Data.SubSequence) throws {
            var slice = line
            if slice.last == 0x0D { slice = slice.dropLast() }
            guard !slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 }),
                let value = try? decoder.decode(In.self, from: Data(slice))
            else { return }
            try put(try RawFormat.line(transform(value)))
        }

        var read: Int64 = 0
        let next: () throws -> Data? = {
            let data = try input.read(upToCount: chunk)
            read += Int64(data?.count ?? 0)
            progress(read)
            return data
        }
        if gzip {
            let raw = try next()
            if let raw, !raw.isEmpty {
                var first: Data? = raw
                // A damaged or truncated stream yields what was readable, as the reader does;
                // a failure to write is still an error.
                do {
                    _ = try Gzip.inflateStream(
                    reading: {
                        if let pending = first {
                            first = nil
                            return pending
                        }
                        return try next()
                    }, emit: { try lines($0, final: false) })
                } catch is Gzip.Error {}
            }
            try lines(Data(), final: true)
        } else {
            while let chunk = try next(), !chunk.isEmpty { try lines(chunk, final: false) }
            try lines(Data(), final: true)
        }
        try writer?.finish()
    }
}
