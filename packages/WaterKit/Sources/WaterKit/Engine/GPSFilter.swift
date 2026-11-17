import Foundation

/// Causal GPS cleaning for live use: decides fix by fix whether to trust a location,
/// and smooths course over ground. See docs/metrics.md, "GPS cleaning".
///
/// The filter never derives speed from positions; it only uses position steps to catch
/// fixes that jump further than the Doppler speed allows.
public struct GPSFilter: Sendable {
    public struct Config: Sendable, Hashable {
        /// Fixes with a larger horizontal accuracy radius (or none) are rejected, m.
        public var maxHorizontalAccuracy: Double = 25
        /// Doppler speeds above this are treated as receiver errors, m/s (about 97 kn).
        public var maxSpeed: Double = 50
        /// Larger changes in Doppler speed between fixes are rejected, m/s².
        public var maxAcceleration: Double = 8
        /// A position step may exceed the Doppler-predicted distance by this factor…
        public var jumpSpeedFactor: Double = 1.5
        /// …plus both accuracy radii plus this margin, m.
        public var jumpMargin: Double = 20
        /// After this many rejections in a row, the next usable fix is accepted as a new
        /// anchor, so one bad anchor cannot lock the filter out.
        public var maxConsecutiveRejections: Int = 5
        /// A fix this long after the last accepted one is accepted as a new anchor, s.
        public var reanchorAfter: Double = 30
        /// Time constant of the course smoothing, s.
        public var courseTimeConstant: Double = 3
        /// Course is only updated at or above this speed; below it, course is noise, m/s.
        public var minSpeedForCourse: Double = 0.5

        public init() {}
    }

    public enum Rejection: String, Sendable, Hashable, Codable {
        case invalidTime
        case outOfOrder
        case invalidCoordinate
        case inaccurate
        case implausibleSpeed
        case implausibleAcceleration
        case jump
    }

    /// An accepted fix, with what the engine needs to account for the step to it.
    public struct Accepted: Sendable, Hashable {
        public var fix: GPSFix
        /// Smoothed course over ground, degrees true; nil until the boat has moved.
        public var course: Double?
        /// True when this fix starts a new anchor (first fix, long gap, or recovery
        /// after rejections). The step from the previous accepted fix is not trustworthy
        /// and must not count toward distance or moving time.
        public var isAnchor: Bool
    }

    public enum Decision: Sendable, Hashable {
        case accepted(Accepted)
        case rejected(Rejection)
    }

    public var config: Config
    public private(set) var last: GPSFix?
    public private(set) var course: Double?
    private var consecutiveRejections = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func ingest(_ fix: GPSFix) -> Decision {
        guard fix.t.isFinite else { return reject(.invalidTime) }
        if let last, fix.t <= last.t { return reject(.outOfOrder) }
        guard fix.latitude.isFinite, fix.longitude.isFinite, abs(fix.latitude) <= 90, abs(fix.longitude) <= 180
        else { return reject(.invalidCoordinate) }
        // A fix without an accuracy value is unknown quality, not perfect quality.
        guard let hacc = fix.horizontalAccuracy, hacc.isFinite, hacc >= 0, hacc <= config.maxHorizontalAccuracy
        else { return reject(.inaccurate) }
        let speed = fix.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let speed, speed > config.maxSpeed { return reject(.implausibleSpeed) }

        guard let last else { return accept(fix, speed: speed, anchor: true) }
        let dt = fix.t - last.t
        if dt > config.reanchorAfter || consecutiveRejections >= config.maxConsecutiveRejections {
            return accept(fix, speed: speed, anchor: true)
        }
        let lastSpeed = last.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let speed, let lastSpeed, abs(speed - lastSpeed) / dt > config.maxAcceleration {
            return reject(.implausibleAcceleration)
        }
        let step = Geo.distance(
            lat1: last.latitude, lon1: last.longitude, lat2: fix.latitude, lon2: fix.longitude)
        // Without a Doppler speed on either side, only the speed limit bounds the step.
        let predictedSpeed =
            (speed == nil && lastSpeed == nil) ? config.maxSpeed : max(speed ?? 0, lastSpeed ?? 0)
        let allowed =
            predictedSpeed * dt * config.jumpSpeedFactor + hacc + (last.horizontalAccuracy ?? 0) + config.jumpMargin
        if step > allowed { return reject(.jump) }
        return accept(fix, speed: speed, anchor: false)
    }

    private mutating func reject(_ reason: Rejection) -> Decision {
        consecutiveRejections += 1
        return .rejected(reason)
    }

    private mutating func accept(_ fix: GPSFix, speed: Double?, anchor: Bool) -> Decision {
        let dt = last.map { fix.t - $0.t } ?? 0
        if let reported = fix.course, reported.isFinite, reported >= 0, let speed, speed >= config.minSpeedForCourse {
            if let current = course, !anchor {
                let alpha = 1 - exp(-dt / config.courseTimeConstant)
                course = Self.normalize(current + alpha * Self.signedDifference(from: current, to: reported))
            } else {
                course = Self.normalize(reported)
            }
        }
        last = fix
        consecutiveRejections = 0
        return .accepted(Accepted(fix: fix, course: course, isAnchor: anchor))
    }

    /// Shortest signed angle from `a` to `b`, degrees in (-180, 180].
    static func signedDifference(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}
