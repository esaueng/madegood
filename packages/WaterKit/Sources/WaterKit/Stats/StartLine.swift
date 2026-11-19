import Foundation

// Race start line (docs/PLAN.md §5, "Race tools"; docs/metrics.md, "Start line").
//
// The geometry is exact on a sphere (unit vectors, the same Earth model as `Geo`), so it
// needs no local projection and works across ±180° and close to the poles. It is not for
// navigation: GPS on the wrist is a few metres off the bow.

/// One end of a start line.
public enum StartLineEnd: String, Sendable, Hashable, Codable, CaseIterable {
    /// The pin (buoy) end: the port end, on the left looking from the pre-start side.
    case pin
    /// The boat (committee) end: the starboard end.
    case boat
}

/// A pinged end: the averaged position and how good it was.
public struct StartLinePing: Sendable, Hashable, Codable {
    public var end: StartLineEnd
    public var latitude: Double
    public var longitude: Double
    /// When the ping was pressed, on the clock of the fixes that made it (unix s in the apps).
    public var time: Double
    /// Fixes averaged.
    public var fixes: Int
    /// Mean horizontal accuracy of those fixes, m, when they reported one.
    public var accuracy: Double?

    public init(end: StartLineEnd, latitude: Double, longitude: Double, time: Double, fixes: Int, accuracy: Double?) {
        self.end = end
        self.latitude = latitude
        self.longitude = longitude
        self.time = time
        self.fixes = fixes
        self.accuracy = accuracy
    }
}

/// Averages the good fixes around a ping press into one position. Each fix is moved to the
/// moment of the press along its own Doppler speed and course, so a boat sailing past
/// the pin pings where it was at the press, not the middle of the window.
public struct StartLinePingAverager: Sendable {
    /// Fixes from this long before the press count, s.
    public static let lookBack = 3.0
    /// The ping waits this long after the press for more fixes, s.
    public static let lookAhead = 2.0
    /// Fixes less accurate than this are left out, m.
    public static let maximumAccuracy = 15.0
    /// A ping needs at least this many usable fixes.
    public static let minimumFixes = 2
    /// A fix without an accuracy counts as this, m (it still needs a weight).
    static let assumedAccuracy = 10.0
    /// Doppler speed above this is not believed for the projection, m/s (about 58 kn).
    static let maximumProjectionSpeed = 30.0

    public let end: StartLineEnd
    public let pressedAt: Double
    private var sum = (x: 0.0, y: 0.0, z: 0.0)
    private var weight = 0.0
    private var accuracySum = 0.0
    private var accuracyCount = 0
    public private(set) var fixes = 0
    private var seen = Set<Double>()

    public init(end: StartLineEnd, pressedAt: Double) {
        self.end = end
        self.pressedAt = pressedAt
    }

    /// The window of fix times this ping uses.
    public var window: ClosedRange<Double> { (pressedAt - Self.lookBack)...(pressedAt + Self.lookAhead) }

    /// Whether the window has passed at `now` (same clock as the fixes).
    public func isComplete(at now: Double) -> Bool { now >= pressedAt + Self.lookAhead }

    /// Adds a fix (`t` on the press's clock). Returns whether it was used: fixes outside
    /// the window, inaccurate, non-finite or already added are skipped.
    @discardableResult
    public mutating func add(_ fix: GPSFix) -> Bool {
        guard window.contains(fix.t), fix.latitude.isFinite, fix.longitude.isFinite,
            abs(fix.latitude) <= 90, !seen.contains(fix.t)
        else { return false }
        if let accuracy = fix.horizontalAccuracy, !(accuracy >= 0 && accuracy <= Self.maximumAccuracy) {
            return false
        }
        guard let (latitude, longitude) = Self.project(fix, to: pressedAt) else { return false }
        seen.insert(fix.t)
        let accuracy = max(1, fix.horizontalAccuracy ?? Self.assumedAccuracy)
        let w = 1 / (accuracy * accuracy)
        let v = SphereVector(latitude: latitude, longitude: longitude)
        sum = (sum.x + w * v.x, sum.y + w * v.y, sum.z + w * v.z)
        weight += w
        if let reported = fix.horizontalAccuracy {
            accuracySum += reported
            accuracyCount += 1
        }
        fixes += 1
        return true
    }

    /// The fix's position moved to `time` along its Doppler speed and course (unchanged
    /// without a believable speed and course). Nil for a non-finite position.
    public static func project(_ fix: GPSFix, to time: Double) -> (latitude: Double, longitude: Double)? {
        guard fix.latitude.isFinite, fix.longitude.isFinite, abs(fix.latitude) <= 90, time.isFinite else {
            return nil
        }
        let dt = time - fix.t
        // Below `StartLine.minimumSpeed` the course is noise: the fix stays where it is.
        guard let speed = fix.speed, let course = fix.course, speed.isFinite, course.isFinite,
            speed >= StartLine.minimumSpeed, speed <= maximumProjectionSpeed, dt != 0
        else { return (fix.latitude, fix.longitude) }
        let moved = Geo.destination(
            lat: fix.latitude, lon: fix.longitude, bearing: dt > 0 ? course : course + 180, distance: speed * abs(dt))
        return (moved.lat, moved.lon)
    }

    /// The averaged ping, or nil with fewer than `minimumFixes` usable fixes.
    public var ping: StartLinePing? {
        guard fixes >= Self.minimumFixes, weight > 0 else { return nil }
        guard let mean = SphereVector(x: sum.x, y: sum.y, z: sum.z).normalized else { return nil }
        return StartLinePing(
            end: end, latitude: mean.latitude, longitude: mean.longitude, time: pressedAt, fixes: fixes,
            accuracy: accuracyCount > 0 ? accuracySum / Double(accuracyCount) : nil)
    }
}

/// A start line between the pin and the boat end.
public struct StartLine: Sendable, Hashable, Codable {
    public var pin: StartLinePing
    public var boat: StartLinePing

    /// Ends closer than this make no line, m: a double ping of the same end.
    public static let minimumLength = 10.0
    /// Longer than any start line, m: two pings this far apart are a mistake.
    public static let maximumLength = 5_000.0
    /// Within this many degrees of square, neither end is favoured.
    public static let squareTolerance = 2.0
    /// Below this Doppler speed the course is not trusted for time to the line, m/s.
    public static let minimumSpeed = 0.3
    /// Times to the line beyond this are not shown, s.
    public static let maximumTimeToLine = 3_600.0

    /// Nil when the ends are not the expected pair or too close or far apart.
    public init?(pin: StartLinePing, boat: StartLinePing) {
        guard pin.end == .pin, boat.end == .boat else { return nil }
        let length = Geo.distance(lat1: pin.latitude, lon1: pin.longitude, lat2: boat.latitude, lon2: boat.longitude)
        guard length >= Self.minimumLength, length <= Self.maximumLength else { return nil }
        self.pin = pin
        self.boat = boat
    }

    /// Length, m.
    public var length: Double {
        Geo.distance(lat1: pin.latitude, lon1: pin.longitude, lat2: boat.latitude, lon2: boat.longitude)
    }

    /// Bearing from the pin to the boat end at the pin, degrees true.
    public var bearing: Double {
        Geo.bearing(lat1: pin.latitude, lon1: pin.longitude, lat2: boat.latitude, lon2: boat.longitude)
    }

    /// Unit normal of the line's great circle, pointing to the course side (left of pin → boat).
    private var normal: SphereVector {
        let a = SphereVector(latitude: pin.latitude, longitude: pin.longitude)
        let b = SphereVector(latitude: boat.latitude, longitude: boat.longitude)
        // `minimumLength` keeps the ends apart, so the cross product is never zero.
        return a.cross(b).normalized ?? SphereVector(x: 0, y: 0, z: 1)
    }

    /// Where a boat is relative to the line, and when it gets there at its current Doppler
    /// speed and course (both optional).
    public func position(latitude: Double, longitude: Double, speed: Double? = nil, course: Double? = nil)
        -> StartLinePosition
    {
        let p = SphereVector(latitude: latitude, longitude: longitude)
        let a = SphereVector(latitude: pin.latitude, longitude: pin.longitude)
        let n = normal
        // Signed cross-track angle: positive on the course side.
        let sine = max(-1, min(1, n.dot(p)))
        let crossTrack = asin(sine) * Geo.earthRadius
        // Along-track from the pin, towards the boat end.
        let along = atan2(n.cross(a).dot(p), a.dot(p)) * Geo.earthRadius
        let distance = -crossTrack

        var closingSpeed: Double?
        if let speed, let course, speed.isFinite, course.isFinite, speed >= Self.minimumSpeed {
            // Velocity on the sphere: speed along the local east/north directions.
            let lat = latitude * .pi / 180
            let lon = longitude * .pi / 180
            let east = SphereVector(x: -sin(lon), y: cos(lon), z: 0)
            let north = SphereVector(x: -sin(lat) * cos(lon), y: -sin(lat) * sin(lon), z: cos(lat))
            let c = course * .pi / 180
            let toCourseSide = speed * (sin(c) * n.dot(east) + cos(c) * n.dot(north))
            let scale = (1 - sine * sine).squareRoot()
            // At a pole east and north are undefined: no rate rather than a wrong one.
            if cos(lat) > 1e-9, scale > 0 { closingSpeed = toCourseSide / scale }
        }
        return StartLinePosition(
            distance: distance, along: along, length: length, closingSpeed: closingSpeed)
    }

    /// How far the line is off square to the wind, and which end is upwind. `windFrom` is
    /// degrees true. With `axisOnly` (a live estimate that has not resolved its side), the
    /// wind is taken to blow from the course side of the line, as at a normal upwind start.
    public func bias(windFrom: Double, axisOnly: Bool) -> LineBias? {
        guard windFrom.isFinite else { return nil }
        // The line's direction at its middle, where the wind is compared with it.
        let a = SphereVector(latitude: pin.latitude, longitude: pin.longitude)
        let b = SphereVector(latitude: boat.latitude, longitude: boat.longitude)
        guard let middle = SphereVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z).normalized else { return nil }
        let lineBearing = Geo.bearing(
            lat1: middle.latitude, lon1: middle.longitude, lat2: boat.latitude, lon2: boat.longitude)
        var wind = GPSFilter.normalize(windFrom)
        if axisOnly {
            // The course side is to the left of pin → boat.
            let courseSide = lineBearing - 90
            if cos((wind - courseSide) * .pi / 180) < 0 { wind = GPSFilter.normalize(wind + 180) }
        }
        // How far the boat end lies upwind of the pin, as a fraction of the length.
        let upwind = cos((lineBearing - wind) * .pi / 180)
        let degrees = asin(max(-1, min(1, upwind))) * 180 / .pi
        let favoured: StartLineEnd? =
            abs(degrees) < Self.squareTolerance ? nil : (degrees > 0 ? .boat : .pin)
        return LineBias(degrees: degrees, advantage: abs(upwind) * length, favoured: favoured, windFrom: wind)
    }
}

/// A boat's place relative to a start line.
public struct StartLinePosition: Sendable, Hashable {
    /// Perpendicular distance to the line (its great circle), m: positive on the
    /// pre-start side, negative when over it on the course side.
    public var distance: Double
    /// Distance along the line from the pin towards the boat end, m: negative past the
    /// pin, more than `length` past the boat.
    public var along: Double
    /// The line's length, m.
    public var length: Double
    /// How fast the boat moves towards the course side, m/s (negative: away from it).
    /// Nil without a usable speed and course.
    public var closingSpeed: Double?

    public init(distance: Double, along: Double, length: Double, closingSpeed: Double?) {
        self.distance = distance
        self.along = along
        self.length = length
        self.closingSpeed = closingSpeed
    }

    /// Over the line: on the course side.
    public var isOver: Bool { distance < 0 }

    /// Between the ends, so crossing here crosses the line itself.
    public var isBetweenEnds: Bool { along >= -0.001 && along <= length + 0.001 }

    /// Seconds to reach the line from the pre-start side at the current speed and course.
    /// Nil when over, not heading towards the line, or slower than `StartLine.minimumSpeed`.
    public var timeToLine: Double? {
        guard !isOver, let closingSpeed, closingSpeed > 0 else { return nil }
        let time = distance / closingSpeed
        return time <= StartLine.maximumTimeToLine ? time : nil
    }

    /// Countdown time left minus time to the line, s: positive means early (time to
    /// burn), negative late. Nil without a time to the line.
    public func timeToBurn(remaining: Double) -> Double? {
        guard let timeToLine, remaining.isFinite else { return nil }
        return remaining - timeToLine
    }
}

/// The line's angle to the wind.
public struct LineBias: Sendable, Hashable {
    /// Degrees off square to the wind: positive when the boat end is upwind (favoured),
    /// negative for the pin.
    public var degrees: Double
    /// How much further upwind the favoured end is, m.
    public var advantage: Double
    /// The upwind end, or nil within `StartLine.squareTolerance` of square.
    public var favoured: StartLineEnd?
    /// The wind direction used, degrees true (flipped to the course side for an axis).
    public var windFrom: Double

    public init(degrees: Double, advantage: Double, favoured: StartLineEnd?, windFrom: Double) {
        self.degrees = degrees
        self.advantage = advantage
        self.favoured = favoured
        self.windFrom = windFrom
    }
}

/// A point on the unit sphere (Earth-centred, x towards 0°N 0°E, z towards the north pole).
struct SphereVector: Sendable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(latitude: Double, longitude: Double) {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        self.init(x: cos(lat) * cos(lon), y: cos(lat) * sin(lon), z: sin(lat))
    }

    var latitude: Double { atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi }
    var longitude: Double { atan2(y, x) * 180 / .pi }

    var normalized: SphereVector? {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 1e-12, length.isFinite else { return nil }
        return SphereVector(x: x / length, y: y / length, z: z / length)
    }

    func dot(_ other: SphereVector) -> Double { x * other.x + y * other.y + z * other.z }

    func cross(_ other: SphereVector) -> SphereVector {
        SphereVector(
            x: y * other.z - z * other.y, y: z * other.x - x * other.z, z: x * other.y - y * other.x)
    }
}

extension StartLinePing {
    /// The `linePing` event data for this ping, written `age` s after it.
    public func eventData(age: Double) -> [String: JSONValue] {
        func round(_ value: Double, _ step: Double) -> Double { (value / step).rounded() * step }
        var data: [String: JSONValue] = [
            "end": .string(end.rawValue), "lat": .number(latitude), "lon": .number(longitude),
            "fixes": .number(Double(fixes)), "age": .number(round(max(0, age), 0.1)),
        ]
        if let accuracy, accuracy.isFinite { data["hacc"] = .number(round(accuracy, 0.1)) }
        return data
    }

    /// Reads a `linePing` event back; `time` is the ping's time on the event's clock.
    public init?(event: SessionEvent) {
        guard event.type == .linePing, let data = event.data,
            case .string(let endName)? = data["end"], let end = StartLineEnd(rawValue: endName),
            case .number(let latitude)? = data["lat"], case .number(let longitude)? = data["lon"]
        else { return nil }
        var fixes = 0
        if case .number(let count)? = data["fixes"] { fixes = Int(count) }
        var age = 0.0
        if case .number(let value)? = data["age"] { age = value }
        var accuracy: Double?
        if case .number(let value)? = data["hacc"] { accuracy = value }
        self.init(
            end: end, latitude: latitude, longitude: longitude, time: event.t - age, fixes: fixes, accuracy: accuracy)
    }
}

/// A wind estimate from the countdown's own sailing (the pre-start), for line bias when no
/// session is recording yet. It feeds the same course histogram as the session's
/// estimate, so it needs both legs to have enough time and only knows the axis.
public struct PrestartWind: Sendable {
    private var histogram = CourseHistogram()
    private var previous: GPSFix?

    public init() {}

    /// Adds a fix; each one stands for the time to the next, capped like the session's.
    public mutating func add(_ fix: GPSFix) {
        if let previous, fix.t > previous.t, let speed = previous.speed, let course = previous.course,
            speed >= CourseHistogram.minimumSailingSpeed
        {
            histogram.add(course: course, seconds: min(fix.t - previous.t, CourseHistogram.maximumFixWeight))
        }
        if previous == nil || fix.t > previous!.t { previous = fix }
    }

    public var estimate: WindEstimate? { histogram.windEstimate() }
}
