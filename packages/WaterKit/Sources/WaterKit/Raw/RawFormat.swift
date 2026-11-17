import Foundation

/// The raw recording format, version 1 (docs/formats.md): a session folder holding
/// `meta.json` and one NDJSON file per stream, each optionally gzipped.
///
/// Timestamps are the sensor's own clock, never converted on device:
/// - `gps`, `hr`, `heading`, `events`: Unix time in seconds (wall clock).
/// - `motion`: seconds since device boot (`CMLogItem.timestamp`).
/// Clock anchors pair the two clocks so readers can put every stream on one timeline.
///
/// The recorder writes lines with `RawFormat.line(_:)` and readers decode them with the
/// same types, so the format is defined once.
public enum RawFormat {
    public static let formatName = "madegood-raw"
    public static let version = 1
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
        /// Clock pairing taken at the start. More anchors may follow in `clock.ndjson`.
        public var clock: ClockAnchor
        public var device: Device
        public var app: App
        /// Requested sampling rates, Hz, by stream name.
        public var requestedRates: [String: Double]?

        public init(
            sessionId: UUID, sport: Sport, startedAt: Double, endedAt: Double? = nil, clock: ClockAnchor,
            device: Device, app: App, requestedRates: [String: Double]? = nil
        ) {
            self.format = RawFormat.formatName
            self.version = RawFormat.version
            self.sessionId = sessionId
            self.sport = sport
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.clock = clock
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

    /// A simultaneous reading of the wall clock and the device-uptime clock (`clock.ndjson`).
    public struct ClockAnchor: Sendable, Hashable, Codable {
        public var unix: Double
        public var uptime: Double

        public init(unix: Double, uptime: Double) {
            self.unix = unix
            self.uptime = uptime
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
    }

    /// `motion.ndjson`. `ts` is device uptime. Accelerations are m/s² (convert from g with
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

    // MARK: Writing

    /// Encodes one NDJSON line, including the trailing newline. Throws on NaN or infinity,
    /// which JSON cannot represent; recorders must map invalid readings to nil first.
    public static func line(_ value: some Encodable) throws -> Data {
        var data = try lineEncoder.encode(value)
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
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}
