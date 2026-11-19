import Foundation
import Testing

@testable import WaterKit

/// Start line geometry against synthetic lines with known answers (docs/metrics.md,
/// "Start line"). Coordinates are made up: fake origins in open water, the antimeridian
/// and near the poles.
@Suite struct StartLineTests {
    static func ping(_ end: StartLineEnd, _ point: (lat: Double, lon: Double)) -> StartLinePing {
        StartLinePing(end: end, latitude: point.lat, longitude: point.lon, time: 0, fixes: 3, accuracy: 4)
    }

    /// A line of `length` m centred on `centre`, pin → boat along `bearing`.
    static func line(
        centre: (lat: Double, lon: Double), bearing: Double, length: Double = 200
    ) throws -> StartLine {
        let pin = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: bearing + 180, distance: length / 2)
        let boat = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: bearing, distance: length / 2)
        return try #require(StartLine(pin: ping(.pin, pin), boat: ping(.boat, boat)))
    }

    /// A point `ahead` m towards the course side (left of pin → boat) of the line's centre
    /// and `along` m towards the boat end, built with great-circle steps.
    static func point(
        centre: (lat: Double, lon: Double), bearing: Double, ahead: Double, along: Double = 0
    ) -> (lat: Double, lon: Double) {
        let onLine = Geo.destination(
            lat: centre.lat, lon: centre.lon, bearing: along >= 0 ? bearing : bearing + 180, distance: abs(along))
        let lineHere =
            along == 0
            ? bearing
            : Geo.bearing(lat1: onLine.lat, lon1: onLine.lon, lat2: centre.lat, lon2: centre.lon)
                + (along > 0 ? 180 : 0)
        return Geo.destination(
            lat: onLine.lat, lon: onLine.lon, bearing: ahead >= 0 ? lineHere - 90 : lineHere + 90, distance: abs(ahead))
    }

    // MARK: Distance

    @Test(arguments: [
        (10.0, -30.0, 90.0), (10.0, -30.0, 37.0), (-45.0, 120.0, 300.0),
        // Across the antimeridian: the pin is at +179.999…, the boat at −179.999….
        (0.0, 180.0, 90.0), (-20.0, -180.0, 75.0),
        // Close to the poles.
        (89.9, 0.0, 90.0), (-89.95, 45.0, 10.0),
    ])
    func signedDistanceMatchesConstruction(lat: Double, lon: Double, bearing: Double) throws {
        let centre = (lat: lat, lon: lon)
        let line = try Self.line(centre: centre, bearing: bearing)
        #expect(abs(line.length - 200) < 0.01)
        for (ahead, along) in [(-150.0, 0.0), (-25, 60), (-3, -40), (0.5, 0), (40, 90), (300, -20)] {
            let p = Self.point(centre: centre, bearing: bearing, ahead: ahead, along: along)
            let position = line.position(latitude: p.lat, longitude: p.lon)
            // Within a centimetre over a few hundred metres.
            #expect(abs(position.distance - -ahead) < 0.01, "ahead \(ahead) along \(along): \(position.distance)")
            #expect(abs(position.along - (100 + along)) < 0.05, "along \(along): \(position.along)")
            #expect(position.isOver == (ahead > 0))
        }
    }

    @Test func pointsOnTheLineAndItsEnds() throws {
        let centre = (lat: 10.0, lon: -30.0)
        let line = try Self.line(centre: centre, bearing: 90)
        let pin = line.position(latitude: line.pin.latitude, longitude: line.pin.longitude)
        #expect(abs(pin.distance) < 1e-4)
        #expect(abs(pin.along) < 1e-4)
        #expect(pin.isBetweenEnds)
        let boat = line.position(latitude: line.boat.latitude, longitude: line.boat.longitude)
        #expect(abs(boat.along - 200) < 1e-4)
        // Beyond the pin and beyond the boat.
        let pastPin = Self.point(centre: centre, bearing: 90, ahead: -10, along: -150)
        #expect(!line.position(latitude: pastPin.lat, longitude: pastPin.lon).isBetweenEnds)
        let pastBoat = Self.point(centre: centre, bearing: 90, ahead: -10, along: 150)
        #expect(!line.position(latitude: pastBoat.lat, longitude: pastBoat.lon).isBetweenEnds)
    }

    @Test func distanceAgreesWithFlatGeometryOverAFewHundredMetres() throws {
        // Line due east at the fake origin; north is the course side. A point 120 m south
        // and 50 m east of the centre is 120 m behind the line.
        let centre = (lat: 10.0, lon: -30.0)
        let line = try Self.line(centre: centre, bearing: 90, length: 400)
        let east = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: 90, distance: 50)
        let p = Geo.destination(lat: east.lat, lon: east.lon, bearing: 180, distance: 120)
        let position = line.position(latitude: p.lat, longitude: p.lon)
        #expect(abs(position.distance - 120) < 0.05)
        #expect(abs(position.along - 250) < 0.05)
    }

    @Test func rejectsShortLongAndSwappedLines() {
        let a = Self.ping(.pin, (10, -30))
        let near = Geo.destination(lat: 10, lon: -30, bearing: 90, distance: 5)
        #expect(StartLine(pin: a, boat: Self.ping(.boat, near)) == nil)
        let far = Geo.destination(lat: 10, lon: -30, bearing: 90, distance: 8_000)
        #expect(StartLine(pin: a, boat: Self.ping(.boat, far)) == nil)
        let ok = Geo.destination(lat: 10, lon: -30, bearing: 90, distance: 150)
        #expect(StartLine(pin: a, boat: Self.ping(.boat, ok)) != nil)
        #expect(StartLine(pin: Self.ping(.boat, (10, -30)), boat: Self.ping(.pin, ok)) == nil)
    }

    // MARK: Time to the line and time to burn

    @Test func timeToLineStraightAtTheLine() throws {
        let centre = (lat: 10.0, lon: -30.0)
        let line = try Self.line(centre: centre, bearing: 90)
        let p = Self.point(centre: centre, bearing: 90, ahead: -50)
        // Heading north (straight at a line running east) at 2.5 m/s: 20 s.
        let position = line.position(latitude: p.lat, longitude: p.lon, speed: 2.5, course: 0)
        let closing = try #require(position.closingSpeed)
        #expect(abs(closing - 2.5) < 1e-6)
        let time = try #require(position.timeToLine)
        #expect(abs(time - 20) < 0.01)
        // 60 s left: 40 s to burn. 15 s left: 5 s late.
        #expect(abs(try #require(position.timeToBurn(remaining: 60)) - 40) < 0.01)
        #expect(abs(try #require(position.timeToBurn(remaining: 15)) - -5) < 0.01)
    }

    @Test(arguments: [(10.0, -30.0), (0.0, 180.0), (89.9, 0.0), (-60.0, -179.9995)])
    func timeToLineAtAnAngle(lat: Double, lon: Double) throws {
        let centre = (lat: lat, lon: lon)
        let bearing = 63.0
        let line = try Self.line(centre: centre, bearing: bearing)
        let p = Self.point(centre: centre, bearing: bearing, ahead: -80)
        // Course 45° off the line's normal, measured locally at the boat.
        let toLine = Geo.bearing(
            lat1: p.lat, lon1: p.lon, lat2: centre.lat, lon2: centre.lon)
        let position = line.position(latitude: p.lat, longitude: p.lon, speed: 4, course: toLine + 45)
        let time = try #require(position.timeToLine)
        #expect(abs(time - 80 / (4 * cos(.pi / 4))) < 0.05, "time \(time)")
    }

    @Test func noTimeToLineWhenOverSlowOrHeadingAway() throws {
        let centre = (lat: 10.0, lon: -30.0)
        let line = try Self.line(centre: centre, bearing: 90)
        let behind = Self.point(centre: centre, bearing: 90, ahead: -50)
        #expect(line.position(latitude: behind.lat, longitude: behind.lon, speed: 3, course: 180).timeToLine == nil)
        #expect(line.position(latitude: behind.lat, longitude: behind.lon, speed: 3, course: 90).timeToLine == nil)
        #expect(line.position(latitude: behind.lat, longitude: behind.lon, speed: 0.1, course: 0).timeToLine == nil)
        #expect(line.position(latitude: behind.lat, longitude: behind.lon).timeToLine == nil)
        #expect(line.position(latitude: behind.lat, longitude: behind.lon).timeToBurn(remaining: 30) == nil)
        let over = Self.point(centre: centre, bearing: 90, ahead: 20)
        let position = line.position(latitude: over.lat, longitude: over.lon, speed: 3, course: 180)
        #expect(position.isOver)
        #expect(position.timeToLine == nil)
        // Sailing back towards the pre-start side: negative closing speed.
        #expect(try #require(position.closingSpeed) < 0)
    }

    @Test func noRateExactlyAtAPole() throws {
        let line = try Self.line(centre: (89.99, 0), bearing: 90)
        let position = line.position(latitude: 90, longitude: 0, speed: 3, course: 0)
        #expect(position.closingSpeed == nil)
        #expect(position.distance.isFinite)
    }

    // MARK: Bias

    @Test func squareLineFavoursNeither() throws {
        let line = try Self.line(centre: (10, -30), bearing: 90)
        let bias = try #require(line.bias(windFrom: 0, axisOnly: false))
        #expect(abs(bias.degrees) < 1e-3)
        #expect(bias.favoured == nil)
        #expect(bias.advantage < 0.01)
    }

    @Test func boatEndUpwind() throws {
        // Wind from north; the boat end is rotated 10° towards the wind.
        let line = try Self.line(centre: (10, -30), bearing: 80)
        let bias = try #require(line.bias(windFrom: 0, axisOnly: false))
        #expect(abs(bias.degrees - 10) < 1e-3)
        #expect(bias.favoured == .boat)
        #expect(abs(bias.advantage - 200 * sin(10 * Double.pi / 180)) < 0.01)
    }

    @Test func pinEndUpwind() throws {
        let line = try Self.line(centre: (10, -30), bearing: 97)
        let bias = try #require(line.bias(windFrom: 355, axisOnly: false))
        #expect(abs(bias.degrees - -12) < 1e-3)
        #expect(bias.favoured == .pin)
    }

    @Test func axisOnlyWindIsTakenFromTheCourseSide() throws {
        let line = try Self.line(centre: (10, -30), bearing: 80)
        // An axis 0°/180° given as 180°: read as wind from 0°, the course side.
        let bias = try #require(line.bias(windFrom: 180, axisOnly: true))
        #expect(abs(bias.windFrom - 0) < 1e-6)
        #expect(bias.favoured == .boat)
        // Resolved wind from behind the line (a downwind start): the pin is upwind.
        let downwind = try #require(line.bias(windFrom: 180, axisOnly: false))
        #expect(downwind.favoured == .pin)
    }

    @Test func nearlySquareWithinTolerance() throws {
        let line = try Self.line(centre: (10, -30), bearing: 91.5)
        #expect(try #require(line.bias(windFrom: 0, axisOnly: true)).favoured == nil)
    }

    // MARK: Ping averaging

    @Test func averagerProjectsMovingFixesToThePress() throws {
        // A boat sails east at 3 m/s past the pin; the press is at t = 100.
        let origin = (lat: 10.0, lon: -30.0)
        var averager = StartLinePingAverager(end: .pin, pressedAt: 100)
        for t in stride(from: 96.0, through: 103, by: 1) {
            let p = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 90, distance: 3 * (t - 100))
            let fix = GPSFix(t: t, latitude: p.lat, longitude: p.lon, horizontalAccuracy: 5, speed: 3, course: 90)
            averager.add(fix)
        }
        // 97…102 are in the window.
        #expect(averager.fixes == 6)
        #expect(!averager.isComplete(at: 101.9))
        #expect(averager.isComplete(at: 102))
        let ping = try #require(averager.ping)
        #expect(Geo.distance(lat1: ping.latitude, lon1: ping.longitude, lat2: origin.lat, lon2: origin.lon) < 0.01)
        #expect(ping.end == .pin)
        #expect(ping.time == 100)
        #expect(ping.accuracy == 5)
    }

    @Test func averagerDropsBadFixesAndAveragesNoise() throws {
        let origin = (lat: 0.0, lon: 179.99999)  // the average must not wrap to 0°
        var averager = StartLinePingAverager(end: .boat, pressedAt: 10)
        let offsets: [(Double, Double)] = [(0, 4), (90, 4), (180, 4), (270, 4)]
        for (index, offset) in offsets.enumerated() {
            let p = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: offset.0, distance: offset.1)
            let used = averager.add(
                GPSFix(t: 9 + Double(index) * 0.5, latitude: p.lat, longitude: p.lon, horizontalAccuracy: 6))
            #expect(used)
        }
        // Inaccurate, duplicate, non-finite and out-of-window fixes are skipped.
        for fix in [
            GPSFix(t: 10.7, latitude: 0, longitude: 0, horizontalAccuracy: 40),
            GPSFix(t: 9, latitude: 0, longitude: 179, horizontalAccuracy: 3),
            GPSFix(t: 10.8, latitude: .nan, longitude: 0, horizontalAccuracy: 3),
            GPSFix(t: 20, latitude: 0, longitude: 179, horizontalAccuracy: 3),
        ] {
            let used = averager.add(fix)
            #expect(!used)
        }
        let ping = try #require(averager.ping)
        #expect(ping.fixes == 4)
        #expect(Geo.distance(lat1: ping.latitude, lon1: ping.longitude, lat2: origin.lat, lon2: origin.lon) < 0.01)
    }

    @Test func averagerWithoutFixesHasNoPing() {
        #expect(StartLinePingAverager(end: .pin, pressedAt: 0).ping == nil)
    }

    // MARK: Event data

    @Test func pingEventRoundTrips() throws {
        let ping = StartLinePing(end: .boat, latitude: 10.001, longitude: -30.002, time: 95, fixes: 4, accuracy: 4.26)
        let data = ping.eventData(age: 5.04)
        #expect(data["end"] == .string("boat"))
        #expect(data["age"] == .number(5))
        #expect(data["hacc"] == .number(4.3))
        let read = try #require(StartLinePing(event: SessionEvent(t: 100, type: .linePing, data: data)))
        #expect(read.end == .boat)
        #expect(read.latitude == 10.001)
        #expect(read.time == 95)
        #expect(read.fixes == 4)
        #expect(StartLinePing(event: SessionEvent(t: 1, type: .mark, data: data)) == nil)
    }

    @Test func pingsAreNotPublished() {
        // Line pings hold positions: the anonymizer drops them like any unlisted type.
        let events = [
            SessionEvent(t: 0, type: .linePing, data: ["lat": .number(1)]),
            SessionEvent(t: 0, type: .start),
        ]
        #expect(Anonymizer.sanitize(events).map(\.type) == [.start])
    }

    // MARK: Pre-start wind

    @Test func prestartWindFromLegs() throws {
        // 40 s on 315° and 40 s on 045°, then a short reach: wind from north.
        var wind = PrestartWind()
        var t = 0.0
        for course in [315.0, 45.0] {
            for _ in 0..<40 {
                wind.add(GPSFix(t: t, latitude: 10, longitude: -30, speed: 3, course: course))
                t += 1
            }
        }
        wind.add(GPSFix(t: t, latitude: 10, longitude: -30, speed: 0.2, course: 90))
        let estimate = try #require(wind.estimate)
        #expect(
            abs(GPSFilter.signedDifference(from: 0, to: estimate.fromDegrees)) <= 5
                || abs(GPSFilter.signedDifference(from: 180, to: estimate.fromDegrees)) <= 5)
        #expect(PrestartWind().estimate == nil)
    }
}
