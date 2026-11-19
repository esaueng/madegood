import Foundation

// All values are SI: metres, seconds, m/s, m/s², rad/s, degrees true (0–360, clockwise
// from north). `t` is seconds since the session's start (`startedAt`). Optional
// values are nil when the sensor reported them as invalid.

/// A location fix. Speed and course are Doppler-derived values from the receiver.
public struct GPSFix: Sendable, Hashable, Codable {
    public var t: Double
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    /// Horizontal accuracy radius, m.
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    /// Speed over ground, m/s.
    public var speed: Double?
    public var speedAccuracy: Double?
    /// Course over ground, degrees true.
    public var course: Double?
    public var courseAccuracy: Double?

    public init(
        t: Double, latitude: Double, longitude: Double, altitude: Double? = nil,
        horizontalAccuracy: Double? = nil, verticalAccuracy: Double? = nil,
        speed: Double? = nil, speedAccuracy: Double? = nil,
        course: Double? = nil, courseAccuracy: Double? = nil
    ) {
        self.t = t
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }
}

/// A heart-rate reading.
public struct HRSample: Sendable, Hashable, Codable {
    public var t: Double
    /// Beats per minute.
    public var bpm: Double

    public init(t: Double, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

public struct Vector3: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)
}

public struct Quaternion: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
}

/// A device-motion sample in the device's reference frame.
public struct MotionSample: Sendable, Hashable, Codable {
    public var t: Double
    /// Acceleration from the user, gravity removed, m/s².
    public var userAcceleration: Vector3
    /// Gravity vector, m/s².
    public var gravity: Vector3
    /// Rotation rate, rad/s.
    public var rotationRate: Vector3
    /// Attitude relative to the reference frame at the start of updates.
    public var attitude: Quaternion
    /// The sensor's own timestamp (device uptime, s) when read from a recording. Unlike `t`,
    /// it never jumps with a wall-clock correction, so analysis that needs a monotonic clock
    /// (strokes) uses it. Nil for samples made in memory.
    public var uptime: Double?

    public init(
        t: Double, userAcceleration: Vector3, gravity: Vector3, rotationRate: Vector3,
        attitude: Quaternion, uptime: Double? = nil
    ) {
        self.t = t
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.uptime = uptime
    }
}

/// A compass heading reading.
public struct HeadingSample: Sendable, Hashable, Codable {
    public var t: Double
    /// Magnetic heading, degrees.
    public var magnetic: Double?
    /// True heading, degrees; nil when location is unavailable.
    public var trueHeading: Double?
    /// Maximum deviation, degrees.
    public var accuracy: Double?

    public init(t: Double, magnetic: Double? = nil, trueHeading: Double? = nil, accuracy: Double? = nil) {
        self.t = t
        self.magnetic = magnetic
        self.trueHeading = trueHeading
        self.accuracy = accuracy
    }
}

/// A point event on the session timeline: a lap, a manual mark, a man-overboard,
/// a detected tack, and so on. `type` is an open set; see `EventType`.
public struct SessionEvent: Sendable, Hashable, Codable {
    public var t: Double
    public var type: EventType
    public var data: [String: JSONValue]?

    public init(t: Double, type: EventType, data: [String: JSONValue]? = nil) {
        self.t = t
        self.type = type
        self.data = data
    }
}

/// An event type name. Unknown names round-trip unchanged so newer files stay readable.
public struct EventType: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let start: EventType = "start"
    public static let stop: EventType = "stop"
    public static let pause: EventType = "pause"
    public static let resume: EventType = "resume"
    public static let mark: EventType = "mark"
    public static let lap: EventType = "lap"
    public static let mob: EventType = "mob"
    public static let tack: EventType = "tack"
    public static let gybe: EventType = "gybe"
    /// A start line end pinged during a race countdown (`StartLinePing.eventData`).
    public static let linePing: EventType = "linePing"
}

/// One sample from any stream, for code that processes streams in time order.
public enum Sample: Sendable, Hashable {
    case gps(GPSFix)
    case hr(HRSample)
    case motion(MotionSample)
    case heading(HeadingSample)
    case event(SessionEvent)

    public var t: Double {
        switch self {
        case .gps(let s): s.t
        case .hr(let s): s.t
        case .motion(let s): s.t
        case .heading(let s): s.t
        case .event(let s): s.t
        }
    }
}
