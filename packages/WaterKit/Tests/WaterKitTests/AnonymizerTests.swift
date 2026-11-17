import Foundation
import Testing

@testable import WaterKit

@Suite struct AnonymizerTests {
    /// A zig-zag sail of `legs` 2 km legs starting at `origin`, 1 fix per second at 5 m/s,
    /// with altitude, a text note, and a MOB event carrying its position.
    static func session(origin: (lat: Double, lon: Double), legs: Int = 5) -> RawSession {
        let startUnix = 1_809_165_600.0
        var fixes: [GPSFix] = []
        var point = origin
        var t = 0.0
        for leg in 0..<legs {
            let course = leg % 2 == 0 ? 45.0 : 135.0
            for _ in 0..<400 {
                fixes.append(
                    GPSFix(
                        t: t, latitude: point.lat, longitude: point.lon, altitude: 12, horizontalAccuracy: 4,
                        verticalAccuracy: 6, speed: 5, course: course))
                point = Geo.destination(lat: point.lat, lon: point.lon, bearing: course, distance: 5)
                t += 1
            }
        }
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .sailing, startedAt: startUnix, endedAt: startUnix + t,
            clock: RawFormat.ClockAnchor(unix: startUnix, uptime: 52_000),
            device: RawFormat.Device(kind: "phone", model: "iPhone18,1", os: "iOS 26.1"),
            app: RawFormat.App(version: "0.1.0", build: "7"))
        let motion = (0..<300).map { i in
            MotionSample(
                t: Double(i) / 100, userAcceleration: Vector3(x: Double(i), y: 0, z: 0), gravity: .zero,
                rotationRate: .zero, attitude: .identity)
        }
        let events = [
            SessionEvent(t: 0, type: .start),
            SessionEvent(t: 100, type: .mark, data: ["note": "near the yacht club", "count": 3]),
            SessionEvent(t: 200, type: .mob, data: ["lat": 47.6, "lon": -122.3, "acknowledged": true]),
            SessionEvent(t: 300, type: .tack, data: ["durationS": 8.1, "speedLossPct": 22, "nested": ["a": 1]]),
            SessionEvent(t: 400, type: "Alice at Lake Example"),
            SessionEvent(t: 500, type: .mark, data: ["Alice": true, "timestamp": 1_809_165_600, "x": -122.3]),
        ]
        return RawSession(
            meta: meta, gps: fixes, motion: motion, hr: [HRSample(t: 5, bpm: 120)],
            heading: [HeadingSample(t: 1, magnetic: 40, trueHeading: 45, accuracy: 5)], events: events,
            clockAnchors: [meta.clock, RawFormat.ClockAnchor(unix: startUnix + 61, uptime: 52_060)], issues: [])
    }

    static let places: [(name: String, lat: Double, lon: Double)] = [
        ("mid-latitude", 47.6, -122.4),
        ("arctic", 69.6, 18.9),
        ("antimeridian", -16.5, 179.995),
        ("southern", -41.3, 174.8),
    ]

    @Test(arguments: places.map(\.name))
    func preservesGeometryAndHidesLocation(place: String) throws {
        let spot = try #require(Self.places.first { $0.name == place })
        let original = Self.session(origin: (spot.lat, spot.lon))
        let anonymized = Anonymizer().anonymize(original)

        #expect(FixtureCheck.problems(in: original).count >= 2)
        #expect(FixtureCheck.problems(in: anonymized) == [])

        // The reference point lands exactly on the fake origin.
        #expect(abs(anonymized.gps[0].latitude - Anonymizer.fakeOrigin.lat) < 1e-9)
        #expect(abs(anonymized.gps[0].longitude - Anonymizer.fakeOrigin.lon) < 1e-9)

        // Every pairwise distance is preserved (the map is a rotation of the sphere).
        let indices = [0, 1, 399, 400, 801, 1_234, 1_999]
        for i in indices {
            for j in indices where j > i {
                let before = distance(original.gps[i], original.gps[j])
                let after = distance(anonymized.gps[i], anonymized.gps[j])
                #expect(abs(before - after) < 1e-3, "distance \(i)-\(j): \(before) vs \(after)")
            }
        }

        // Step bearings stay within meridian convergence of the original (< 0.2° here).
        for i in stride(from: 0, to: 1_999, by: 97) {
            let before = Geo.bearing(
                lat1: original.gps[i].latitude, lon1: original.gps[i].longitude,
                lat2: original.gps[i + 1].latitude, lon2: original.gps[i + 1].longitude)
            let after = Geo.bearing(
                lat1: anonymized.gps[i].latitude, lon1: anonymized.gps[i].longitude,
                lat2: anonymized.gps[i + 1].latitude, lon2: anonymized.gps[i + 1].longitude)
            let difference = abs((before - after + 540).truncatingRemainder(dividingBy: 360) - 180)
            #expect(difference < 0.2, "bearing at \(i): \(before) vs \(after)")
        }

        // Speed, course, relative time, and sensor data are untouched.
        #expect(anonymized.gps.map(\.speed) == original.gps.map(\.speed))
        #expect(anonymized.gps.map(\.course) == original.gps.map(\.course))
        #expect(anonymized.gps.map(\.t) == original.gps.map(\.t))
        #expect(anonymized.motion == original.motion)
        #expect(anonymized.heading.map(\.trueHeading) == original.heading.map(\.trueHeading))
        #expect(anonymized.heading.allSatisfy { $0.magnetic == nil })
        #expect(anonymized.hr == original.hr)
    }

    @Test func replacesTimeIdentityAltitudeAndText() {
        let original = Self.session(origin: (47.6, -122.4))
        let id = UUID()
        let anonymized = Anonymizer(sessionId: id).anonymize(original)

        #expect(anonymized.meta.sessionId == id)
        #expect(anonymized.meta.startedAt == Anonymizer.fakeStart)
        #expect(anonymized.meta.endedAt == Anonymizer.fakeStart + 2_000)
        #expect(
            anonymized.meta.clock == RawFormat.ClockAnchor(unix: Anonymizer.fakeStart, uptime: Anonymizer.fakeUptime))
        #expect(anonymized.clockAnchors.count == 1)
        #expect(anonymized.gps.allSatisfy { $0.altitude == nil && $0.verticalAccuracy == nil })
        #expect(anonymized.meta.device == original.meta.device)

        let data = anonymized.events.map(\.data)
        // Only allowed types survive, and only allowed small numeric fields within them.
        #expect(anonymized.events.map(\.type) == [.start, .mark, .mob, .tack, .mark])
        #expect(data == [nil, nil, nil, ["durationS": 8.1, "speedLossPct": 22], nil])
    }

    @Test func writtenFolderReadsBackIdentically() throws {
        let anonymized = Anonymizer().anonymize(Self.session(origin: (69.6, 18.9)))
        let folder = try TempFolder()
        let output = folder.url.appendingPathComponent("anon")
        try RawSessionWriter.write(anonymized, to: output)

        let reread = try RawSessionReader.read(folder: output)
        #expect(reread.issues.isEmpty)
        #expect(FixtureCheck.problems(in: reread) == [])
        #expect(FixtureCheck.problems(inFolder: output) == [])
        #expect(reread.gps.count == anonymized.gps.count)
        #expect(zip(reread.motion, anonymized.motion).allSatisfy { abs($0.t - $1.t) < 1e-9 })
        #expect(reread.events.map(\.data) == anonymized.events.map(\.data))
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(
            files == [
                "events.ndjson.gz", "gps.ndjson.gz", "heading.ndjson.gz", "hr.ndjson.gz", "meta.json",
                "motion.ndjson.gz",
            ])
    }

    @Test func anonymizesTracksAndDropsSummary() throws {
        var track = Self.session(origin: (-41.3, 174.8)).track()
        track.summary = ["bbox": [174.8, -41.3]]
        let anonymized = Anonymizer().anonymize(track)
        #expect(anonymized.summary == nil)
        #expect(anonymized.startedAt == Date(timeIntervalSince1970: Anonymizer.fakeStart))
        #expect(FixtureCheck.problems(in: anonymized) == [])
        #expect(FixtureCheck.problems(in: track).count >= 3)
        // Survives the track codec's rounding.
        let decoded = try TrackCodec.decode(TrackCodec.encode(anonymized))
        #expect(FixtureCheck.problems(in: decoded) == [])
    }

    @Test func emptyAndSingleFixSessions() {
        var session = Self.session(origin: (0.5, 0.5))
        session.gps = []
        #expect(Anonymizer().anonymize(session).gps.isEmpty)
        session.gps = [GPSFix(t: 0, latitude: 51, longitude: 0)]
        let moved = Anonymizer().anonymize(session).gps[0]
        #expect(moved.latitude == Anonymizer.fakeOrigin.lat && moved.longitude == Anonymizer.fakeOrigin.lon)
    }

    private func distance(_ a: GPSFix, _ b: GPSFix) -> Double {
        Geo.distance(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }
}
