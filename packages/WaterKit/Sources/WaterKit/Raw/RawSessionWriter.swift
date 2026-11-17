import Foundation

/// Writes a `RawSession` as a raw recording v1 folder (docs/formats.md), with a single
/// clock anchor taken from `meta.clock`. Used by the anonymizer and by tests; the
/// recorder app writes streams incrementally with `RawFormat.line(_:)` instead.
public enum RawSessionWriter {
    public static func write(_ session: RawSession, to folder: URL, gzip: Bool = true) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = session.meta
        let start = meta.startedAt
        let uptimeAtStart = meta.clock.uptime - (meta.clock.unix - start)

        try RawFormat.encodeMeta(meta).write(to: folder.appendingPathComponent(RawFormat.metaFileName))

        try writeStream(
            .gps,
            session.gps.map { fix in
                RawFormat.GPSLine(
                    ts: start + fix.t, lat: fix.latitude, lon: fix.longitude, alt: fix.altitude,
                    hacc: fix.horizontalAccuracy, vacc: fix.verticalAccuracy, spd: fix.speed,
                    spdacc: fix.speedAccuracy, crs: fix.course, crsacc: fix.courseAccuracy)
            }, folder: folder, gzip: gzip)
        try writeStream(
            .motion,
            session.motion.map { sample in
                RawFormat.MotionLine(
                    ts: uptimeAtStart + sample.t, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
                    rotationRate: sample.rotationRate, attitude: sample.attitude)
            }, folder: folder, gzip: gzip)
        try writeStream(
            .hr, session.hr.map { RawFormat.HRLine(ts: start + $0.t, bpm: $0.bpm) },
            folder: folder, gzip: gzip)
        try writeStream(
            .heading,
            session.heading.map {
                RawFormat.HeadingLine(ts: start + $0.t, mag: $0.magnetic, trueHeading: $0.trueHeading, acc: $0.accuracy)
            }, folder: folder, gzip: gzip)
        try writeStream(
            .events, session.events.map { RawFormat.EventLine(ts: start + $0.t, type: $0.type, data: $0.data) },
            folder: folder, gzip: gzip)
    }

    private static func writeStream<Line: Encodable>(
        _ stream: RawFormat.Stream, _ lines: [Line], folder: URL, gzip: Bool
    ) throws {
        guard !lines.isEmpty else { return }
        var data = Data()
        for line in lines { data.append(try RawFormat.line(line)) }
        if gzip {
            try Gzip.compress(data).write(to: folder.appendingPathComponent(stream.gzippedFileName))
        } else {
            try data.write(to: folder.appendingPathComponent(stream.fileName))
        }
    }
}
