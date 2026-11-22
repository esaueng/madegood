import Foundation

/// The raw recording format, version 2 (docs/formats.md): a session folder holding
/// `meta.json` and one NDJSON file per stream, each optionally gzipped.
///
/// Every timestamp is an absolute time in Unix seconds; no file holds a reading of the
/// device's boot-time clock:
/// - `gps`, `hr`, `heading`, `events`: the wall clock.
/// - `motion`: the session's monotonic clock, `startedAt + (uptime − uptime at start)`,
///   computed on the device. It equals the wall clock at the start and never jumps when
///   the system clock is corrected.
/// Clock anchors in `clock.ndjson` pair the two (wall and monotonic, both absolute) so
/// readers can put every stream on one timeline. Version 1 stored raw device uptime in
/// `meta.clock`, motion and clock lines; `RawSessionReader` still reads it (`RawFormat.V1`).
///
/// The recorder writes lines with `RawFormat.line(_:)` and readers decode them with the
/// same types, so the format is defined once.
public enum RawFormat {
    public static let formatName = "madegood-raw"
    public static let version = 2
    /// Versions `RawSessionReader` reads. Writers always write `version`.
    public static let readableVersions: Set<Int> = [1, 2]
    public static let metaFileName = "meta.json"
    /// Standard gravity, for converting accelerometer values from g to m/s².
    public static let standardGravity = 9.80665

    public enum Stream: String, Sendable, CaseIterable {
        case gps, motion, hr, heading, events, clock

        public var fileName: String { "\(rawValue).ndjson" }
        public var gzippedFileName: String { "\(rawValue).ndjson.gz" }
    }

    // MARK: meta.json

    public struct Meta: Sendable, Hashable, Codable {
        /// Always `madegood-raw`.
        public var format: String
        public var version: Int
        public var sessionId: UUID
        public var sport: Sport
        /// Unix time of the session start, s. Session time `t` is measured from here.
        public var startedAt: Double
        /// Unix time of the session end; nil if the recording did not stop cleanly.
        public var endedAt: Double?
        public var device: Device
        public var app: App
        /// Requested sampling rates, Hz, by stream name.
        public var requestedRates: [String: Double]?

        public init(
            sessionId: UUID, sport: Sport, startedAt: Double, endedAt: Double? = nil,
            device: Device, app: App, requestedRates: [String: Double]? = nil
        ) {
            self.format = RawFormat.formatName
            self.version = RawFormat.version
            self.sessionId = sessionId
            self.sport = sport
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.device = device
            self.app = app
            self.requestedRates = requestedRates
        }
    }

    /// The recording device. Never includes the user-assigned device name.
    public struct Device: Sendable, Hashable, Codable {
        /// `watch` or `phone`.
        public var kind: String
        /// Hardware model identifier, e.g. `Watch7,5`.
        public var model: String
        /// OS name and version, e.g. `watchOS 26.1`.
        public var os: String

        public init(kind: String, model: String, os: String) {
            self.kind = kind
            self.model = model
            self.os = os
        }
    }

    public struct App: Sendable, Hashable, Codable {
        public var version: String
        public var build: String

        public init(version: String, build: String) {
            self.version = version
            self.build = build
        }
    }

    // MARK: Stream lines

    /// A simultaneous reading of the wall clock and the session's monotonic clock, both as
    /// Unix seconds (`clock.ndjson`). The start is an implicit anchor: `mono` equals `unix`
    /// at `meta.startedAt`. The recorder writes another every 60 s and whenever the system
    /// clock changes.
    public struct ClockAnchor: Sendable, Hashable, Codable {
        public var unix: Double
        public var mono: Double

        public init(unix: Double, mono: Double) {
            self.unix = unix
            self.mono = mono
        }
    }

    /// The session's monotonic clock on the device: turns boot-time readings (motion
    /// timestamps, `ProcessInfo.systemUptime`) into absolute times. Only these absolute
    /// times are written; the uptime reading itself never leaves memory.
    public struct MonotonicClock: Sendable, Hashable {
        public let startUnix: Double
        let startUptime: Double

        /// `startUnix` and `startUptime` read together at the session start.
        public init(startUnix: Double, startUptime: Double) {
            self.startUnix = startUnix
            self.startUptime = startUptime
        }

        /// The absolute monotonic time of an uptime reading, Unix s.
        public func absolute(uptime: Double) -> Double {
            // Subtract the large values first so sub-millisecond offsets keep full precision.
            startUnix + (uptime - startUptime)
        }

        /// A clock anchor for a wall-clock and uptime reading taken together.
        public func anchor(unix: Double, uptime: Double) -> ClockAnchor {
            ClockAnchor(unix: unix, mono: absolute(uptime: uptime))
        }
    }

    /// Version 1, read for recordings made before version 2. It stored device uptime.
    public enum V1 {
        /// `meta.clock` and `clock.ndjson` lines of version 1.
        public struct ClockAnchor: Sendable, Hashable, Codable {
            public var unix: Double
            public var uptime: Double

            public init(unix: Double, uptime: Double) {
                self.unix = unix
                self.uptime = uptime
            }
        }

        /// The version 1 fields a version 2 `Meta` does not have.
        public struct MetaClock: Sendable, Hashable, Codable {
            public var clock: ClockAnchor
        }

        /// A complete version 1 `meta.json`, for writing old recordings in tests and tools.
        public static func encodeMeta(_ meta: Meta, clock: ClockAnchor) throws -> Data {
            struct Legacy: Encodable {
                var meta: Meta
                var clock: ClockAnchor
                enum Keys: String, CodingKey { case clock }
                func encode(to encoder: any Encoder) throws {
                    var legacy = meta
                    legacy.version = 1
                    try legacy.encode(to: encoder)
                    var container = encoder.container(keyedBy: Keys.self)
                    try container.encode(clock, forKey: .clock)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Legacy(meta: meta, clock: clock))
        }
    }

    /// `gps.ndjson`. Invalid values (CoreLocation reports -1) are written as absent.
    public struct GPSLine: Sendable, Hashable, Codable {
        public var ts: Double
        public var lat: Double
        public var lon: Double
        public var alt: Double?
        public var hacc: Double?
        public var vacc: Double?
        public var spd: Double?
        public var spdacc: Double?
        public var crs: Double?
        public var crsacc: Double?

        public init(
            ts: Double, lat: Double, lon: Double, alt: Double? = nil, hacc: Double? = nil, vacc: Double? = nil,
            spd: Double? = nil, spdacc: Double? = nil, crs: Double? = nil, crsacc: Double? = nil
        ) {
            self.ts = ts
            self.lat = lat
            self.lon = lon
            self.alt = alt
            self.hacc = hacc
            self.vacc = vacc
            self.spd = spd
            self.spdacc = spdacc
            self.crs = crs
            self.crsacc = crsacc
        }

        enum CodingKeys: String, CodingKey {
            case ts, lat, lon, alt, hacc, vacc, spd, spdacc, crs, crsacc
        }

        /// Writes every value as reported. GPS is small (about 1 Hz), and analysis compares
        /// almost every field with a threshold: accuracy (25 m, 15 m, 20°), speed (the 50 m/s
        /// limit, auto-pause), the distance between fixes (the jump limit) and course steps
        /// (manoeuvres). Rounding any of them could turn a decision made live into a
        /// different one on replay.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ts, forKey: .ts)
            try c.encode(lat, forKey: .lat)
            try c.encode(lon, forKey: .lon)
            try c.encodeIfPresent(alt, forKey: .alt)
            try c.encodeIfPresent(hacc, forKey: .hacc)
            try c.encodeIfPresent(vacc, forKey: .vacc)
            try c.encodeIfPresent(spd, forKey: .spd)
            try c.encodeIfPresent(spdacc, forKey: .spdacc)
            try c.encodeIfPresent(crs, forKey: .crs)
            try c.encodeIfPresent(crsacc, forKey: .crsacc)
        }
    }

    /// `motion.ndjson`. `ts` is the session's monotonic clock, Unix s (version 1: device
    /// uptime). Accelerations are m/s² (convert from g with
    /// `standardGravity`), rotation rate rad/s, attitude a unit quaternion.
    public struct MotionLine: Sendable, Hashable, Codable {
        public var ts: Double
        public var ax: Double, ay: Double, az: Double
        public var gx: Double, gy: Double, gz: Double
        public var rx: Double, ry: Double, rz: Double
        public var qx: Double, qy: Double, qz: Double, qw: Double

        public init(
            ts: Double, userAcceleration a: Vector3, gravity g: Vector3, rotationRate r: Vector3,
            attitude q: Quaternion
        ) {
            self.ts = ts
            ax = a.x
            ay = a.y
            az = a.z
            gx = g.x
            gy = g.y
            gz = g.z
            rx = r.x
            ry = r.y
            rz = r.z
            qx = q.x
            qy = q.y
            qz = q.z
            qw = q.w
        }

        enum CodingKeys: String, CodingKey {
            case ts, ax, ay, az, gx, gy, gz, rx, ry, rz, qx, qy, qz, qw
        }

        /// Writes the values rounded to `Resolution` (docs/formats.md, "Resolution"), and
        /// `ts` exactly: readers place it relative to clock anchors.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            typealias R = Resolution
            let rounding = LineRounding(encoder)
            try c.encode(ts, forKey: .ts)
            for (key, value) in [(CodingKeys.ax, ax), (.ay, ay), (.az, az), (.gx, gx), (.gy, gy), (.gz, gz)] {
                try c.encode(rounding(value, R.acceleration), forKey: key)
            }
            for (key, value) in [(CodingKeys.rx, rx), (.ry, ry), (.rz, rz)] {
                try c.encode(rounding(value, R.rotationRate), forKey: key)
            }
            for (key, value) in [(CodingKeys.qx, qx), (.qy, qy), (.qz, qz), (.qw, qw)] {
                try c.encode(rounding(value, R.attitude), forKey: key)
            }
        }
    }

    /// `hr.ndjson`. `ts` is the sample's start date.
    public struct HRLine: Sendable, Hashable, Codable {
        public var ts: Double
        public var bpm: Double

        public init(ts: Double, bpm: Double) {
            self.ts = ts
            self.bpm = bpm
        }
    }

    /// `heading.ndjson`. Degrees; `true` is absent when unavailable.
    public struct HeadingLine: Sendable, Hashable, Codable {
        public var ts: Double
        public var mag: Double?
        public var trueHeading: Double?
        public var acc: Double?

        enum CodingKeys: String, CodingKey {
            case ts, mag, acc
            case trueHeading = "true"
        }

        public init(ts: Double, mag: Double? = nil, trueHeading: Double? = nil, acc: Double? = nil) {
            self.ts = ts
            self.mag = mag
            self.trueHeading = trueHeading
            self.acc = acc
        }

        /// Writes the headings rounded to `Resolution`; `acc` is written as reported, like
        /// every accuracy.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            typealias R = Resolution
            let rounding = LineRounding(encoder)
            try c.encode(ts, forKey: .ts)
            try c.encodeIfPresent(mag.map { rounding($0, R.heading) }, forKey: .mag)
            try c.encodeIfPresent(trueHeading.map { rounding($0, R.heading) }, forKey: .trueHeading)
            try c.encodeIfPresent(acc, forKey: .acc)
        }
    }

    /// Passes at most one heading line per `interval` of `ts`. CoreLocation delivers
    /// heading at about 50 Hz with no filter; the recording keeps about 1 Hz (PLAN §4.2,
    /// `Resolution.headingInterval`). A `ts` earlier than the last one passed (a wall-clock
    /// correction) passes and restarts the interval.
    public struct HeadingThrottle: Sendable, Hashable {
        public let interval: Double
        private var last: Double?

        public init(interval: Double = Resolution.headingInterval) {
            self.interval = interval
        }

        /// Whether to write a line at `ts`; records it as the last line when it does.
        public mutating func admit(_ ts: Double) -> Bool {
            if let last, ts >= last, ts - last < interval { return false }
            last = ts
            return true
        }
    }

    /// `events.ndjson`: start, stop, pause, resume, mark, lap, mob, ...
    public struct EventLine: Sendable, Hashable, Codable {
        public var ts: Double
        public var type: String
        public var data: [String: JSONValue]?

        public init(ts: Double, type: EventType, data: [String: JSONValue]? = nil) {
            self.ts = ts
            self.type = type.rawValue
            self.data = data
        }
    }

    // MARK: Resolution

    /// The steps writers round motion and heading values to (docs/formats.md, "Resolution").
    /// Each is far below the sensor's noise, so analysis of a written recording differs from
    /// the live readings by no more than noise would, and short numbers keep the files small.
    /// Readers must not assume finer values. GPS lines, accuracy fields (heading `acc`) and
    /// timestamps are never rounded: analysis compares them with thresholds and places
    /// readings relative to clock anchors and pause events, and rounding must not change
    /// those decisions.
    public enum Resolution {
        /// `motion` user acceleration and gravity, m/s².
        public static let acceleration = 1e-3
        /// `motion` rotation rate, rad/s.
        public static let rotationRate = 1e-4
        /// `motion` attitude quaternion components.
        public static let attitude = 1e-5
        /// `heading` `mag`, `true`, degrees.
        public static let heading = 0.1
        /// The shortest time between two heading lines, s (about 1 Hz).
        public static let headingInterval = 1.0
    }

    /// `value` rounded to the nearest multiple of `step`, a negative power of ten (or 1).
    /// Divides by the exact power of ten rather than multiplying by `step`, so the result
    /// is the double nearest the decimal and JSON prints it short (`0.079`, never
    /// `0.07900000000000001`). The result is within half a step of `value`, plus the error
    /// of the scaling product (under 1e-14 of the value), so a value within that distance
    /// of a half step may round either way. Values too large to scale exactly, and NaN, are
    /// returned unchanged; -0 becomes 0.
    public static func round(_ value: Double, to step: Double) -> Double {
        let scale = (1 / step).rounded()
        let scaled = (value * scale).rounded()
        guard scaled.magnitude < 0x1p53 else { return value }
        return scaled / scale + 0
    }

    /// Rounds a line's values to `Resolution` unless its encoder asks for exact values.
    struct LineRounding {
        static let exactValuesKey = CodingUserInfoKey(rawValue: "app.madegood.raw.exactValues")!
        let isOn: Bool

        init(_ encoder: any Encoder) {
            isOn = encoder.userInfo[Self.exactValuesKey] as? Bool != true
        }

        func callAsFunction(_ value: Double, _ step: Double) -> Double {
            isOn ? RawFormat.round(value, to: step) : value
        }
    }

    // MARK: Writing

    /// Encodes one NDJSON line, including the trailing newline. Throws on NaN or infinity,
    /// which JSON cannot represent; recorders must map invalid readings to nil first.
    /// Values are rounded to `Resolution`; `exactValues` writes them unrounded, for
    /// converting a recording without changing it.
    public static func line(_ value: some Encodable, exactValues: Bool = false) throws -> Data {
        let encoder = lineEncoder
        if exactValues { encoder.userInfo[LineRounding.exactValuesKey] = true }
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    /// Encodes `meta.json`.
    public static func encodeMeta(_ meta: Meta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(meta)
    }

    private static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys give every line of a stream the same key order, which compresses better.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
