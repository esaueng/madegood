import Foundation
import Testing

@testable import WaterKit

/// Raw format version 3: motion lines are arrays of their 14 numbers. Everything else, and
/// every value, is as in version 2, so the same recording reads back the same either way.
@Suite struct RawFormatV3Tests {
    static let start = 1_809_165_600.0

    /// A paddling session with every stream, on the session's monotonic clock.
    static func session() -> RawSession {
        var simulator = PaddleMotionSimulator(
            sport: .kayak, segments: [PaddleMotionSimulator.Segment(duration: 60, strokeRate: 62)])
        simulator.seed = 7
        let motion = simulator.generate().samples.map { sample in
            var placed = sample
            placed.monotonic = start + sample.t
            return placed
        }
        let gps = (0..<60).map { second in
            GPSFix(
                t: Double(second), latitude: 10, longitude: -30 + Double(second) * 2e-5, altitude: 3.25,
                horizontalAccuracy: 4.7, speed: 2.04, course: 89.6)
        }
        var meta = RawSessionReaderTests.meta(endedAt: start + 60)
        meta.startedAt = start
        return RawSession(
            meta: meta, gps: gps, motion: motion,
            hr: [HRSample(t: 5, bpm: 121), HRSample(t: 10, bpm: 124)],
            heading: [HeadingSample(t: 1, magnetic: 80.4, trueHeading: 88.1, accuracy: 11.6)],
            events: [SessionEvent(t: 0, type: .start), SessionEvent(t: 60, type: .stop)])
    }

    static func motionLines(in folder: URL) throws -> [Substring] {
        let data = try Gzip.decompress(Data(contentsOf: folder.appendingPathComponent("motion.ndjson.gz")))
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    @Test func aMotionLineIsAnArrayInKeyOrder() throws {
        let line = RawFormat.MotionLine(
            ts: Self.start + 0.0123456, userAcceleration: Vector3(x: 0.1, y: -0.2, z: 0.3),
            gravity: Vector3(x: 1.5, y: -9.7, z: 0.25), rotationRate: Vector3(x: 0.0123, y: -1.5, z: 2),
            attitude: Quaternion(x: 0.5, y: -0.5, z: 0.25, w: -0.625))
        let v3 = String(decoding: try RawFormat.line(line, version: 3), as: UTF8.self)
        #expect(v3 == "[1809165600.0123456,0.1,-0.2,0.3,1.5,-9.7,0.25,0.0123,-1.5,2,0.5,-0.5,0.25,-0.625]\n")
        // Version 2 writes the same numbers with keys.
        let v2 = String(decoding: try RawFormat.line(line, version: 2), as: UTF8.self)
        #expect(v2.hasPrefix(#"{"ax":0.1,"ay":-0.2,"az":0.3,"#))
        #expect(v2.count > v3.count + 50)
        #expect(try JSONDecoder().decode(RawFormat.MotionLine.self, from: Data(v3.utf8)) == line)
        #expect(try JSONDecoder().decode(RawFormat.MotionLine.self, from: Data(v2.utf8)) == line)
    }

    /// The same session written as version 2 and as version 3 reads back identically, and
    /// analysis gives the same result; version 3 is smaller.
    @Test func versions2And3ReadBackTheSame() throws {
        let temp = try TempFolder()
        let session = Self.session()
        let v2Folder = temp.url.appendingPathComponent("v2")
        let v3Folder = temp.url.appendingPathComponent("v3")
        try RawSessionWriter.write(session, to: v2Folder, version: 2)
        try RawSessionWriter.write(session, to: v3Folder)

        let v2 = try RawSessionReader.read(folder: v2Folder)
        let v3 = try RawSessionReader.read(folder: v3Folder)
        #expect(v2.meta.version == 2)
        #expect(v3.meta.version == 3)
        #expect(v2.issues.isEmpty && v3.issues.isEmpty)
        #expect(v3.motion.count == session.motion.count)
        #expect(v3.motion == v2.motion)
        #expect(v3.gps == v2.gps)
        #expect(v3.hr == v2.hr)
        #expect(v3.heading == v2.heading)
        #expect(v3.events == v2.events)
        #expect(v3.clockAnchors == v2.clockAnchors)

        let before = StrokeAnalysis.detect(session: v2)
        let after = StrokeAnalysis.detect(session: v3)
        #expect(before.strokes.count > 40)
        #expect(after.strokes == before.strokes)

        // Only the motion file differs; every other file is byte for byte the same.
        for stream in RawFormat.Stream.allCases where stream != .motion {
            let name = stream.gzippedFileName
            #expect(
                FileManager.default.contents(atPath: v3Folder.appendingPathComponent(name).path)
                    == FileManager.default.contents(atPath: v2Folder.appendingPathComponent(name).path), "\(name)")
        }
        let v2Motion = try Self.motionLines(in: v2Folder)
        let v3Motion = try Self.motionLines(in: v3Folder)
        #expect(v2Motion.allSatisfy { $0.hasPrefix("{") })
        #expect(v3Motion.allSatisfy { $0.hasPrefix("[") })
        let size = { (folder: URL) in
            try Data(contentsOf: folder.appendingPathComponent("motion.ndjson.gz")).count
        }
        #expect(try size(v3Folder) < size(v2Folder))
    }

    @Test func streamWritersWriteTheirRecordingsVersion() throws {
        let temp = try TempFolder()
        let line = RawFormat.MotionLine(
            ts: Self.start, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.8), rotationRate: .zero,
            attitude: .identity)
        for version in [2, 3] {
            let folder = temp.url.appendingPathComponent("v\(version)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writer = RawStreamWriter(stream: .motion, folder: folder, version: version)
            #expect(writer.version == version)
            writer.append(line)
            #expect(writer.flushAndWait())
            let written = try Self.motionLines(in: folder)
            #expect(written.count == 1)
            #expect(written.first?.first == (version == 2 ? "{" : "["))
        }
        #expect(RawStreamWriter(stream: .motion, folder: temp.url).version == RawFormat.version)
    }

    /// A damaged array is skipped like any damaged line: too few or too many values, or a
    /// value that is not a number.
    @Test func damagedArraysAreSkipped() throws {
        let folder = try TempFolder()
        var meta = RawSessionReaderTests.meta()
        meta.version = 3
        try folder.write(RawFormat.metaFileName, RawFormat.encodeMeta(meta))
        let good = "[\(RawSessionReaderTests.startUnix + 1),0,0,0,0,0,-9.8,0,0,0,0,0,0,1]"
        let motion = [
            good,
            "[\(RawSessionReaderTests.startUnix + 2),0,0,0,0,0,-9.8,0,0,0,0,0,0]",
            "[\(RawSessionReaderTests.startUnix + 3),0,0,0,0,0,-9.8,0,0,0,0,0,0,1,7]",
            "[\(RawSessionReaderTests.startUnix + 4),0,0,0,0,0,-9.8,0,0,0,0,0,0,\"1\"]",
            "[\(RawSessionReaderTests.startUnix + 5),0,0,0,0,0,-9.8,0,0,0,0,0,0,null]",
            good,
        ]
        try folder.write("motion.ndjson", Data((motion.joined(separator: "\n") + "\n").utf8))
        let session = try RawSessionReader.read(folder: folder.url)
        #expect(session.motion.count == 2)
        #expect(session.issues.map(\.line) == [2, 3, 4, 5])
        #expect(session.motion.first?.gravity == Vector3(x: 0, y: 0, z: -9.8))
        #expect(session.motion.first?.attitude == .identity)
    }

    /// Converting a version 1 recording writes version 3 motion arrays with every value
    /// exactly as recorded, not rounded.
    @Test func convertingVersion1WritesExactArrays() throws {
        let temp = try TempFolder()
        let v1Folder = temp.url.appendingPathComponent("v1")
        let converted = temp.url.appendingPathComponent("converted")
        _ = try RawFormatVersionTests.writeV1(to: v1Folder, duration: 20)
        #expect(try RawFormatConversion.convertToCurrent(folder: v1Folder, into: converted))
        #expect(try RawSessionReader.readMeta(folder: converted).version == 3)

        let before = try RawSessionReader.read(folder: v1Folder)
        let after = try RawSessionReader.read(folder: converted)
        #expect(after.issues.isEmpty)
        #expect(after.motion.count == before.motion.count)
        let same = zip(after.motion, before.motion).allSatisfy { a, b in
            a.userAcceleration == b.userAcceleration && a.gravity == b.gravity && a.rotationRate == b.rotationRate
                && a.attitude == b.attitude
        }
        #expect(same)
        let motion = try String(
            contentsOf: converted.appendingPathComponent(RawFormat.Stream.motion.fileName), encoding: .utf8)
        #expect(motion.split(separator: "\n").allSatisfy { $0.hasPrefix("[") })
    }

    /// Only the writable versions may be written: version 1 stored device uptime.
    @Test func writableVersions() {
        #expect(RawFormat.writableVersions == [2, 3])
        #expect(RawFormat.writableVersions.isSubset(of: RawFormat.readableVersions))
        #expect(RawFormat.writableVersions.contains(RawFormat.version))
    }
}

extension FixtureCheckTests {
    /// Anonymized fixtures are written as version 3; their motion lines must be arrays of
    /// exactly 14 numbers, so nothing can hide in an extra value.
    @Test func version3MotionMustBeArraysOfFourteenNumbers() throws {
        let temp = try TempFolder()
        defer { withExtendedLifetime(temp) {} }
        let folder = try Self.anonymizedFolder(in: temp)
        #expect(try RawSessionReader.readMeta(folder: folder).version == 3)
        let motion = folder.appendingPathComponent("motion.ndjson")
        #expect(try String(contentsOf: motion, encoding: .utf8).hasPrefix("["))
        #expect(FixtureCheck.problems(inFolder: folder) == [])

        try Self.append("[946728001,0,0,0,0,0,-9.8,0,0,0,0,0,0,1,47.6]\n", to: motion)
        let keys = ["ts", "ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw"]
        let object = "{" + keys.map { "\"\($0)\":1" }.joined(separator: ",") + "}\n"
        try Self.append(object, to: motion)
        let problems = FixtureCheck.problems(inFolder: folder)
        #expect(problems.contains("motion.ndjson: 2 lines are not arrays of 14 numbers"))
    }
}
