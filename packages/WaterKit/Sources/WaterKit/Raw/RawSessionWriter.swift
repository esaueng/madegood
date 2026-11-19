import Foundation

/// Writes a `RawSession` as a raw recording folder of the current version (docs/formats.md):
/// every timestamp absolute, motion on the monotonic clock, and the session's clock
/// anchors after the start in `clock.ndjson`. Used by the anonymizer, and by tests; the recorder app writes streams
/// incrementally with `RawFormat.line(_:)` instead. Events are written in session-time
/// order, so the recorded order of events around a wall-clock correction is not kept; to
/// convert a recording exactly, use `RawFormatConversion`.
public enum RawSessionWriter {
    public static func write(_ session: RawSession, to folder: URL, gzip: Bool = true) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = session.meta
        meta.version = RawFormat.version
        let start = meta.startedAt
        // On the current version the monotonic clock equals the wall clock at the start.
        let monoShift = start - session.monotonicStart

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
                    ts: sample.monotonic.map { $0 + monoShift } ?? start + sample.t, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
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
        // Corrections only when motion carries its monotonic time: samples made in memory
        // place motion by `t`, which already includes any correction.
        let keepsMonotonic = session.motion.allSatisfy { $0.monotonic != nil }
        let anchors = (keepsMonotonic ? session.clockAnchors : [])
            .map { RawFormat.ClockAnchor(unix: $0.unix, mono: $0.mono + monoShift) }
            .filter { !($0.unix == start && $0.mono == start) }
        try writeStream(.clock, anchors, folder: folder, gzip: gzip)
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
