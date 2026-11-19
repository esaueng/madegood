import Foundation
import Testing

@testable import WaterKit

/// A deterministic synthetic paddle: 120 s heading east from (0, 0) at 1 m/s, with a
/// 5 s sprint at 3 m/s, one inaccurate fix, 100 Hz motion with a 1 s dropout, 1 Hz heart
/// rate, and start/mark/stop events.
enum SyntheticPaddle {
    static let startUnix = 1_809_165_600.0
    static let startUptime = 1_000.0
    static let sprint = 60.0..<65.0

    static func speed(at t: Double) -> Double { sprint.contains(t) ? 3 : 1 }

    /// Distance along the course at time t, m (speed changes at whole seconds).
    static func along(_ t: Double) -> Double {
        stride(from: 0.0, to: t, by: 1).reduce(0) { $0 + speed(at: $1) }
    }

    static func write(to folder: URL) throws {
        let meta = RawFormat.Meta(
            sessionId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, sport: .kayak,
            startedAt: startUnix, endedAt: startUnix + 120,
            device: RawFormat.Device(kind: "watch", model: "Test1,1", os: "watchOS 26.0"),
            app: RawFormat.App(version: "0.0.0", build: "0"), requestedRates: ["motion": 100, "gps": 1])
        // A version 1 recording (device-uptime motion), read by the old-version reader.
        try RawFormat.V1.encodeMeta(meta, clock: .init(unix: startUnix, uptime: startUptime))
            .write(to: folder.appendingPathComponent("meta.json"))

        var gps = Data()
        for second in 0...119 {
            let t = Double(second)
            let point = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: along(t))
            let hacc = second == 30 ? 50.0 : 5.0
            gps += try RawFormat.line(
                RawFormat.GPSLine(
                    ts: startUnix + t, lat: point.lat, lon: point.lon, hacc: hacc,
                    spd: speed(at: t), crs: 90))
        }
        try gps.write(to: folder.appendingPathComponent("gps.ndjson"))

        var motion = Data()
        for tick in 0..<12_000 where !(4_000..<4_100).contains(tick) {
            let uptime = startUptime + Double(tick) / 100
            motion += try RawFormat.line(
                RawFormat.MotionLine(
                    ts: uptime, userAcceleration: Vector3(x: sin(Double(tick) / 10), y: 0, z: 0),
                    gravity: Vector3(x: 0, y: 0, z: -RawFormat.standardGravity),
                    rotationRate: .zero, attitude: .identity))
        }
        try Gzip.compress(motion).write(to: folder.appendingPathComponent("motion.ndjson.gz"))

        var hr = Data()
        for second in 0...119 {
            hr += try RawFormat.line(RawFormat.HRLine(ts: startUnix + Double(second), bpm: 100 + Double(second % 21)))
        }
        try hr.write(to: folder.appendingPathComponent("hr.ndjson"))

        var events = Data()
        for (t, type) in [(0.0, EventType.start), (45, .mark), (90, .mark), (120, .stop)] {
            events += try RawFormat.line(RawFormat.EventLine(ts: startUnix + t, type: type))
        }
        try events.write(to: folder.appendingPathComponent("events.ndjson"))
    }
}

@Suite struct SessionStatsTests {
    @Test func summarizesASyntheticRawSession() throws {
        let folder = try TempFolder()
        try SyntheticPaddle.write(to: folder.url)
        let stats = SessionStats(session: try RawSessionReader.read(folder: folder.url))

        #expect(stats.sport == "kayak")
        #expect(stats.duration == 120)
        #expect(stats.streams["gps"]?.count == 120)
        #expect(stats.streams["gps"]?.medianRate == 1)
        #expect(stats.streams["motion"]?.count == 11_900)
        #expect(abs((stats.streams["motion"]?.medianRate ?? 0) - 100) < 0.01)
        #expect(stats.streams["motion"]?.gaps == 1)
        #expect(abs((stats.streams["motion"]?.longestGap ?? 0) - 1.01) < 1e-6)
        #expect(stats.streams["hr"]?.count == 120)

        // The inaccurate fix lies on the straight course, so skipping it keeps the distance.
        #expect(stats.acceptedFixes == 119)
        #expect(stats.rejectedFixes == 1)
        let expectedDistance = SyntheticPaddle.along(119)  // 129 m
        #expect(abs(stats.distance - expectedDistance) < 0.01)
        #expect(abs((stats.averageSpeed ?? 0) - expectedDistance / 119) < 1e-3)

        #expect(abs((stats.maxSpeed2s ?? 0) - 3) < 1e-9)
        // Best 10 s: any window covering the sprint integrates 4 s at 3 m/s, two 1 s ramps
        // averaging 2 m/s, and 4 s at 1 m/s: 20 m over 10 s.
        #expect(abs((stats.maxSpeed10s ?? 0) - 2) < 1e-9)

        #expect(stats.heartRateMax == 120)
        #expect(stats.events == ["start": 1, "mark": 2, "stop": 1])
        #expect(stats.issues.isEmpty)
    }

    @Test func trackFileGivesTheSameHeadlineFigures() throws {
        let folder = try TempFolder()
        try SyntheticPaddle.write(to: folder.url)
        let session = try RawSessionReader.read(folder: folder.url)
        let fromRaw = SessionStats(session: session)
        let fromTrack = SessionStats(track: try TrackCodec.decode(TrackCodec.encode(session.track())))

        #expect(abs(fromTrack.distance - fromRaw.distance) < 0.05)
        #expect(fromTrack.maxSpeed2s == fromRaw.maxSpeed2s)
        #expect(fromTrack.events == fromRaw.events)
        #expect(fromTrack.streams["motion"] == nil)
    }

    @Test func windowedBestIgnoresSpikesAndGaps() {
        // A single 10 m/s spike between 1 m/s fixes must not become a 2 s best of 10.
        let spiky = (0...20).map { GPSFix(t: Double($0), latitude: 0, longitude: 0, speed: $0 == 10 ? 10 : 1) }
        let best = SessionStats.bestAverageSpeed(spiky, window: 2)
        #expect(best == 5.5)  // trapezoid over [9, 11]: (1+10)/2 + (10+1)/2 over 2 s

        // Fixes 30 s apart never form a 10 s window.
        let sparse = [
            GPSFix(t: 0, latitude: 0, longitude: 0, speed: 5), GPSFix(t: 30, latitude: 0, longitude: 0, speed: 5),
        ]
        #expect(SessionStats.bestAverageSpeed(sparse, window: 10) == nil)
    }

    @Test func windowsHaveExactlyTheRequestedLength() {
        // Uneven spacing: a window anchored at a fix and cut at exactly 2 s averages 3.5 m/s.
        // (Stretching to the next fix gave 3.0; a window starting between fixes reaches 4.0.)
        let fixes = [(0.0, 0.0), (1.5, 6.0), (3.0, 0.0)].map {
            GPSFix(t: $0.0, latitude: 0, longitude: 0, horizontalAccuracy: 5, speed: $0.1)
        }
        #expect(SessionStats.bestAverageSpeed(fixes, window: 2) == 3.5)
    }

    @Test func averageSpeedUsesDopplerNotPositionChanges() {
        let east10m = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: 10)
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0),
            gps: [
                GPSFix(t: 0, latitude: 0, longitude: 0, horizontalAccuracy: 5, speed: 0),
                GPSFix(t: 2, latitude: east10m.lat, longitude: east10m.lon, horizontalAccuracy: 5, speed: 0),
            ])
        let stats = SessionStats(track: track)
        #expect(abs(stats.distance - 10) < 1e-6)
        #expect(stats.averageSpeed == 0)
    }

    @Test func fixesWithoutAccuracyAreRejected() {
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0),
            gps: [
                GPSFix(t: 0, latitude: 0, longitude: 0, speed: 1),
                GPSFix(t: 1, latitude: 0, longitude: 1, speed: 1),
            ])
        let stats = SessionStats(track: track)
        #expect(stats.acceptedFixes == 0)
        #expect(stats.rejectedFixes == 2)
        #expect(stats.distance == 0)
    }

    @Test func unsortedTrackColumnsAreOrderedFirst() {
        let fixes = [0.0, 2, 1, 3].map { metres in
            let point = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: metres)
            return GPSFix(t: metres, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: 1)
        }
        let stats = SessionStats(
            track: Track(sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0), gps: fixes))
        #expect(abs(stats.distance - 3) < 1e-6)
        #expect(stats.streams["gps"]?.medianRate == 1)
    }

    @Test func textReportShowsTheKeyFigures() throws {
        let folder = try TempFolder()
        try SyntheticPaddle.write(to: folder.url)
        let report = SessionStats(session: try RawSessionReader.read(folder: folder.url)).textReport()
        #expect(report.contains("Duration  2:00 (120.0 s)"))
        #expect(report.contains("Distance  0.13 km  (119 fixes used, 1 rejected"))
        #expect(report.contains("Max speed 2 s: 3.00 m/s (5.83 kn)"))
        #expect(report.contains("Events    mark ×2, start ×1, stop ×1"))
        #expect(report.contains("Issues    none"))
    }

    @Test func fixedFormatting() {
        #expect(SessionStats.fixed(1.005, 2) == "1.00" || SessionStats.fixed(1.005, 2) == "1.01")
        #expect(SessionStats.fixed(1.5, 2) == "1.50")
        #expect(SessionStats.fixed(-0.04, 1) == "-0.0" || SessionStats.fixed(-0.04, 1) == "0.0")
        #expect(SessionStats.fixed(-2.25, 1) == "-2.3" || SessionStats.fixed(-2.25, 1) == "-2.2")
        #expect(SessionStats.fixed(12, 0) == "12")
        #expect(SessionStats.clock(3725) == "1:02:05")
    }

    @Test func geoRoundTrips() {
        let point = Geo.destination(lat: 60, lon: 179.9995, bearing: 90, distance: 100)
        #expect(point.lon < -179)  // wrapped across the antimeridian
        #expect(abs(Geo.distance(lat1: 60, lon1: 179.9995, lat2: point.lat, lon2: point.lon) - 100) < 1e-6)
        #expect(abs(Geo.bearing(lat1: 0, lon1: 0, lat2: 0, lon2: 0.001) - 90) < 1e-9)
    }
}
