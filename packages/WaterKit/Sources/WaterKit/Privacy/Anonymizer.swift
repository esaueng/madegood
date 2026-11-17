import Foundation

/// Removes where and when a session happened while keeping what algorithms need:
/// speeds, courses, headings, sensor data, and the relative geometry of the track.
///
/// - **Positions:** the track is rotated on the sphere so its reference point (the first
///   accurate fix) lands on `fakeOrigin`, keeping each point's distance and bearing from
///   that reference. Distances between any two points are preserved; true-north
///   directions elsewhere differ by the convergence of meridians (under 0.2° for a 10 km
///   track at 60° latitude), so recorded courses and headings stay consistent to within
///   that.
/// - **Time:** every timestamp is shifted so the session starts at `fakeStart`; relative
///   times are unchanged. Device uptime is rebased to `fakeUptime`.
/// - **Identifiers:** a new session ID. Altitude and vertical accuracy are dropped
///   (altitude can identify a lake), and so is the magnetic heading: its difference from
///   the true heading is the local magnetic declination, which narrows down the region.
/// - **Events:** only `allowedEventTypes` are kept, and their data only keeps
///   `allowedEventDataKeys` with small finite numbers. Everything else (free text, names,
///   coordinates, timestamps, unknown types) is removed. The track summary is dropped and
///   can be recomputed.
/// - **Kept:** sport, device kind/model/OS, app version, requested sampling rates, true
///   heading, and all motion data (CoreMotion's default attitude frame has an arbitrary
///   yaw, not magnetic north).
public struct Anonymizer: Sendable {
    /// Open Atlantic Ocean, far from land and from (0, 0), which some tools treat as "no fix".
    public static let fakeOrigin = (lat: 10.0, lon: -30.0)
    /// 2000-01-01T12:00:00Z.
    public static let fakeStart = 946_728_000.0
    public static let fakeUptime = 1_000.0
    /// Every anonymized position must lie within this distance of `fakeOrigin`, m.
    public static let checkRadius = 200_000.0

    public var sessionId: UUID

    public init(sessionId: UUID = UUID()) {
        self.sessionId = sessionId
    }

    // MARK: Raw sessions

    public func anonymize(_ session: RawSession) -> RawSession {
        let reference = Self.reference(for: session.gps)
        var meta = session.meta
        meta.sessionId = sessionId
        meta.endedAt = meta.endedAt.map { Self.fakeStart + ($0 - meta.startedAt) }
        meta.startedAt = Self.fakeStart
        meta.clock = RawFormat.ClockAnchor(unix: Self.fakeStart, uptime: Self.fakeUptime)

        var result = session
        result.meta = meta
        result.gps = session.gps.map { move($0, reference: reference) }
        result.events = Self.sanitize(session.events)
        result.heading = session.heading.map { heading in
            var clean = heading
            clean.magnetic = nil
            return clean
        }
        result.clockAnchors = [meta.clock]
        result.issues = []
        return result
    }

    // MARK: Tracks

    public func anonymize(_ track: Track) -> Track {
        let reference = Self.reference(for: track.gps)
        var result = track
        result.sessionId = sessionId
        result.startedAt = Date(timeIntervalSince1970: Self.fakeStart)
        result.gps = track.gps.map { move($0, reference: reference) }
        result.events = Self.sanitize(track.events)
        result.summary = nil
        return result
    }

    // MARK: Positions

    /// The first fix with good accuracy, else the first fix.
    static func reference(for fixes: [GPSFix]) -> (lat: Double, lon: Double)? {
        let fix = fixes.first { ($0.horizontalAccuracy ?? 0) <= SessionStats.maxHorizontalAccuracy } ?? fixes.first
        return fix.map { ($0.latitude, $0.longitude) }
    }

    func move(_ fix: GPSFix, reference: (lat: Double, lon: Double)?) -> GPSFix {
        var moved = fix
        if let reference {
            let point = Self.move(lat: fix.latitude, lon: fix.longitude, reference: reference)
            moved.latitude = point.lat
            moved.longitude = point.lon
        }
        moved.altitude = nil
        moved.verticalAccuracy = nil
        return moved
    }

    static func move(lat: Double, lon: Double, reference: (lat: Double, lon: Double)) -> (lat: Double, lon: Double) {
        let distance = Geo.distance(lat1: reference.lat, lon1: reference.lon, lat2: lat, lon2: lon)
        guard distance > 0 else { return fakeOrigin }
        let bearing = Geo.bearing(lat1: reference.lat, lon1: reference.lon, lat2: lat, lon2: lon)
        return Geo.destination(lat: fakeOrigin.lat, lon: fakeOrigin.lon, bearing: bearing, distance: distance)
    }

    // MARK: Event data

    /// Event types that may appear in a published recording.
    public static let allowedEventTypes: Set<EventType> = [
        .start, .stop, .pause, .resume, .mark, .lap, .mob, .tack, .gybe,
    ]
    /// Event data fields that may appear in a published recording (analysis outputs).
    public static let allowedEventDataKeys: Set<String> = ["durationS", "speedLossPct", "angleDeg"]
    /// Larger values are rejected so a timestamp or coordinate can't hide in an allowed field.
    public static let maxEventDataMagnitude = 10_000.0

    static func sanitize(_ events: [SessionEvent]) -> [SessionEvent] {
        events.compactMap { event in
            guard allowedEventTypes.contains(event.type) else { return nil }
            var clean = event
            let kept = (event.data ?? [:]).filter { key, value in
                allowedEventDataKeys.contains(key) && isAllowedEventValue(value)
            }
            clean.data = kept.isEmpty ? nil : kept
            return clean
        }
    }

    static func isAllowedEventValue(_ value: JSONValue) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite && abs(number) <= maxEventDataMagnitude
    }
}
