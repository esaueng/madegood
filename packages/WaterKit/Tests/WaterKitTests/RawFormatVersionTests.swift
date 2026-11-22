import Foundation
import Testing

@testable import WaterKit

/// Raw recording versions 2 and 3: only absolute timestamps on disk, version 1 still readable,
/// and converting a version 1 recording changes nothing the analysis sees.
@Suite struct RawFormatVersionTests {
    static let start = 946_684_800.0
    static let uptime0 = 5_000.0

    static func meta(sport: Sport = .kayak, endedAt: Double? = nil) -> RawFormat.Meta {
        RawFormat.Meta(
            sessionId: UUID(uuidString: "00000000-0000-4000-8000-0000000000AB")!, sport: sport,
            startedAt: start, endedAt: endedAt,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
    }

    static func lines<T: Encodable>(_ items: [T]) throws -> Data {
        var data = Data()
        for item in items { data.append(try RawFormat.line(item)) }
        return data
    }

    /// A version 1 paddling recording on disk: device-uptime motion, a 20 s backward wall
    /// clock correction 35 s in (the monotonic clock does not jump), a pause and a resume.
    static func writeV1(to folder: URL, duration: Double = 90) throws -> PaddleMotionSimulator.Output {
        var simulator = PaddleMotionSimulator(
            sport: .kayak, segments: [PaddleMotionSimulator.Segment(duration: duration, strokeRate: 60)])
        simulator.seed = 11
        let output = simulator.generate()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RawFormat.V1.encodeMeta(meta(endedAt: start + duration), clock: .init(unix: start, uptime: uptime0))
            .write(to: folder.appendingPathComponent(RawFormat.metaFileName))
        try lines(output.samples.map { sample in
            RawFormat.MotionLine(
                ts: uptime0 + sample.t, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
                rotationRate: sample.rotationRate, attitude: sample.attitude)
        }).write(to: folder.appendingPathComponent(RawFormat.Stream.motion.fileName))
        try lines([RawFormat.V1.ClockAnchor(unix: start + 15, uptime: uptime0 + 35)])
            .write(to: folder.appendingPathComponent(RawFormat.Stream.clock.fileName))
        try lines((0..<Int(duration)).map { second in
            // GPS on the wall clock, which reads 20 s behind after the correction.
            let wall = Double(second) < 35 ? start + Double(second) : start + Double(second) - 20
            return RawFormat.GPSLine(ts: wall, lat: 10, lon: -30 + Double(second) * 2e-5, hacc: 5, spd: 2, crs: 90)
        }).write(to: folder.appendingPathComponent(RawFormat.Stream.gps.fileName))
        try lines([
            RawFormat.EventLine(ts: start, type: .start), RawFormat.EventLine(ts: start + 30, type: .pause),
            RawFormat.EventLine(ts: start + 20, type: .resume), RawFormat.EventLine(ts: start + duration - 20, type: .stop),
        ]).write(to: folder.appendingPathComponent(RawFormat.Stream.events.fileName))
        return output
    }

    @Test func monotonicClockTurnsUptimeIntoAbsoluteTime() {
        let clock = RawFormat.MonotonicClock(startUnix: Self.start, startUptime: Self.uptime0)
        #expect(clock.absolute(uptime: Self.uptime0) == Self.start)
        #expect(clock.absolute(uptime: Self.uptime0 + 12.5) == Self.start + 12.5)
        #expect(clock.anchor(unix: Self.start + 40, uptime: Self.uptime0 + 60) == .init(unix: Self.start + 40, mono: Self.start + 60))
    }

    @Test func convertingVersion1KeepsEveryTimeAndTheStrokes() throws {
        let temp = try TempFolder()
        let v1Folder = temp.url.appendingPathComponent("v1")
        let v2Folder = temp.url.appendingPathComponent("v2")
        _ = try Self.writeV1(to: v1Folder)

        let v1 = try RawSessionReader.read(folder: v1Folder)
        #expect(v1.meta.version == 1)
        #expect(v1.issues.isEmpty)
        // On the monotonic clock: motion is placed by uptime from the start (the simulated
        // sensor jitters its timestamps by up to 0.5 ms), pauses keep their recorded order.
        let first = try #require(v1.motion.first)
        #expect(abs((first.monotonic ?? 0) - Self.start - first.t) < 1e-6)
        #expect(v1.pauseEventsOnMonotonicClock?.map(\.t) == [30, 40])

        #expect(try RawFormatConversion.convertToCurrent(folder: v1Folder, into: v2Folder))
        let v2 = try RawSessionReader.read(folder: v2Folder)
        #expect(v2.meta.version == RawFormat.version)
        #expect(v2.issues.isEmpty)

        // Every stream lands at the same session times.
        #expect(zip(v1.motion, v2.motion).allSatisfy { abs($0.t - $1.t) < 1e-6 })
        #expect(v1.motion.count == v2.motion.count)
        #expect(v2.gps.map(\.t) == v1.gps.map(\.t))
        #expect(v2.events.map(\.t) == v1.events.map(\.t))
        #expect(v2.pauseEventsOnMonotonicClock?.map(\.t) == v1.pauseEventsOnMonotonicClock?.map(\.t))
        #expect(v2.clockAnchors == v1.clockAnchors)

        // Stroke detection (on the monotonic clock) is unchanged.
        let before = StrokeAnalysis.detect(session: v1)
        let after = StrokeAnalysis.detect(session: v2)
        #expect(before.strokes.count > 40)
        #expect(after.strokes.count == before.strokes.count)
        #expect(zip(after.strokes, before.strokes).allSatisfy { abs($0.t - $1.t) < 1e-6 })
        #expect(SessionStats(session: v2).strokes?.count == SessionStats(session: v1).strokes?.count)
    }

    @Test func version2FilesHoldNoBootTimeReading() throws {
        let temp = try TempFolder()
        let v1Folder = temp.url.appendingPathComponent("v1")
        let v2Folder = temp.url.appendingPathComponent("v2")
        _ = try Self.writeV1(to: v1Folder)
        try RawFormatConversion.convertToCurrent(folder: v1Folder, into: v2Folder)
        // The wall-clock streams are copied byte for byte.
        for stream in [RawFormat.Stream.gps, .events] {
            #expect(
                try Data(contentsOf: v1Folder.appendingPathComponent(stream.fileName))
                    == Data(contentsOf: v2Folder.appendingPathComponent(stream.fileName)))
        }
        // A current recording is left alone.
        #expect(try !RawFormatConversion.convertToCurrent(folder: v2Folder, into: temp.url.appendingPathComponent("v3")))

        let meta = try String(contentsOf: v2Folder.appendingPathComponent(RawFormat.metaFileName), encoding: .utf8)
        #expect(!meta.contains("uptime") && !meta.contains("clock"))
        let clock = try String(
            contentsOf: v2Folder.appendingPathComponent(RawFormat.Stream.clock.fileName), encoding: .utf8)
        #expect(!clock.contains("uptime"))
        #expect(clock.contains("\"mono\""))
        // Motion is absolute: at the session start, not near the device's uptime.
        let motion = try String(
            contentsOf: v2Folder.appendingPathComponent(RawFormat.Stream.motion.fileName), encoding: .utf8)
        let first = try JSONDecoder().decode(
            RawFormat.MotionLine.self, from: Data(motion.split(separator: "\n")[0].utf8))
        #expect(abs(first.ts - Self.start) < 0.001)
        for line in motion.split(separator: "\n").prefix(1000) {
            let ts = try JSONDecoder().decode(RawFormat.MotionLine.self, from: Data(line.utf8)).ts
            #expect(ts > Self.start - 0.001 && ts < Self.start + 100)
        }
    }

    /// Versions 2 and 3 differ only in the shape of motion lines.
    @Test(arguments: [2, 3]) func aClockJumpDuringASessionKeepsMonotonicOrder(version: Int) throws {
        let temp = try TempFolder()
        let folder = temp.url
        // As the recorder writes it: motion on the monotonic clock, an anchor when the wall
        // clock was set forward 3600 s at 10 s in, a pause and resume either side of it.
        let clock = RawFormat.MonotonicClock(startUnix: Self.start, startUptime: Self.uptime0)
        var meta = Self.meta(sport: .sup, endedAt: Self.start + 3620)
        meta.version = version
        try RawFormat.encodeMeta(meta).write(to: folder.appendingPathComponent(RawFormat.metaFileName))
        try Self.lines([clock.anchor(unix: Self.start + 3610, uptime: Self.uptime0 + 10)])
            .write(to: folder.appendingPathComponent(RawFormat.Stream.clock.fileName))
        var motion = Data()
        for tick in 0..<2000 {
            let line = RawFormat.MotionLine(
                ts: clock.absolute(uptime: Self.uptime0 + Double(tick) / 100), userAcceleration: .zero,
                gravity: Vector3(x: 0, y: 0, z: -9.8), rotationRate: .zero, attitude: .identity)
            motion.append(try RawFormat.line(line, version: version))
        }
        try motion.write(to: folder.appendingPathComponent(RawFormat.Stream.motion.fileName))
        try Self.lines([
            RawFormat.EventLine(ts: Self.start + 5, type: .pause),
            RawFormat.EventLine(ts: Self.start + 3612, type: .resume),
        ]).write(to: folder.appendingPathComponent(RawFormat.Stream.events.fileName))

        let session = try RawSessionReader.read(folder: folder)
        #expect(session.meta.version == version)
        #expect(session.issues.isEmpty)
        #expect(session.motion.count == 2000)
        // Motion after the jump moves to the corrected wall clock, in order and without a gap.
        let times = session.motion.map(\.t)
        #expect(times.isSorted())
        #expect(abs((times.last ?? 0) - (3600 + 19.99)) < 1e-6)
        // On the monotonic clock the pause lasted 7 s, not an hour.
        #expect(session.pauseEventsOnMonotonicClock?.map(\.t) == [5, 12])
    }

    @Test func rejectsVersionsItDoesNotKnow() throws {
        let temp = try TempFolder()
        try Data(#"{"format":"madegood-raw","version":99}"#.utf8)
            .write(to: temp.url.appendingPathComponent(RawFormat.metaFileName))
        #expect(throws: RawSessionReader.Error.self) { try RawSessionReader.read(folder: temp.url) }
    }
}

extension RawFormatVersionTests {
    /// The writer (used by the anonymizer) also produces version 2 with the same times.
    @Test func writerOutputIsCurrentVersion() throws {
        let temp = try TempFolder()
        let v1Folder = temp.url.appendingPathComponent("v1")
        _ = try Self.writeV1(to: v1Folder)
        let v1 = try RawSessionReader.read(folder: v1Folder)
        let written = temp.url.appendingPathComponent("written")
        try RawSessionWriter.write(v1, to: written, gzip: false)
        let reread = try RawSessionReader.read(folder: written)
        #expect(reread.meta.version == RawFormat.version)
        #expect(zip(reread.motion, v1.motion).allSatisfy { abs($0.t - $1.t) < 1e-6 })
        #expect(reread.clockAnchors == v1.clockAnchors)
    }
}
