import Foundation

/// Watches a swing circle. Distances (including horizontal accuracy) are in metres,
/// bearings in degrees true, and fix timestamps in seconds on the caller's monotonic clock.
public struct AnchorAlarm: Sendable {
    public static let maximumAccuracy = 25.0
    public static let confirmationDelay = 10.0
    public static let radiusRange = 10.0...500.0

    public struct Point: Codable, Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double

        public init?(latitude: Double, longitude: Double) {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct Reading: Sendable {
        public let distance: Double
        /// Nil at the anchor itself, where there is no direction back to it.
        public let bearing: Double?
    }

    public enum FixAssessment: Equatable, Sendable {
        case unusable, withinOrUncertain, outside, driftConfirmed
    }

    public let anchor: Point
    public let radius: Double
    public private(set) var isDrifting = false

    private var lastFixTime: Double?
    private var firstOutsideTime: Double?
    private var outsideCount = 0

    public init?(anchor: Point, radius: Double) {
        guard Self.radiusRange.contains(radius),
            Point(latitude: anchor.latitude, longitude: anchor.longitude) != nil
        else { return nil }
        self.anchor = anchor
        self.radius = radius
    }

    public func reading(at boat: Point) -> Reading {
        let distance = Geo.distance(
            lat1: boat.latitude, lon1: boat.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        let bearing =
            distance < 0.001
            ? nil
            : Geo.bearing(
                lat1: boat.latitude, lon1: boat.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        return Reading(distance: distance, bearing: bearing)
    }

    public func isClearlyOutside(at boat: Point, accuracy: Double) -> Bool {
        reading(at: boat).distance - accuracy > radius
    }

    /// Returns true once per alert. Three distinct usable fixes must be clearly
    /// outside, spanning at least 10 s. Weak fixes do not count as evidence, and
    /// a usable fix whose accuracy circle crosses the boundary starts a new run.
    @discardableResult
    public mutating func ingest(_ fix: GPSFix) -> Bool {
        assess(fix) == .driftConfirmed
    }

    /// Classifies a fix for both drift evidence and GPS watchdog renewal.
    /// Gaps between fixes leave the existing evidence in place.
    public mutating func assess(_ fix: GPSFix) -> FixAssessment {
        guard fix.t.isFinite, lastFixTime.map({ fix.t > $0 }) ?? true,
            let boat = Point(latitude: fix.latitude, longitude: fix.longitude),
            let accuracy = fix.horizontalAccuracy, (0...Self.maximumAccuracy).contains(accuracy)
        else { return .unusable }
        lastFixTime = fix.t
        guard isClearlyOutside(at: boat, accuracy: accuracy) else {
            resetEvidence()
            return .withinOrUncertain
        }
        guard !isDrifting else { return .outside }

        let start = firstOutsideTime ?? fix.t
        firstOutsideTime = start
        outsideCount += 1
        isDrifting = outsideCount >= 3 && fix.t - start >= Self.confirmationDelay
        return isDrifting ? .driftConfirmed : .outside
    }

    /// Keeps the circle and starts a fresh confirmation window.
    public mutating func acknowledge() {
        isDrifting = false
        resetEvidence()
    }

    private mutating func resetEvidence() {
        firstOutsideTime = nil
        outsideCount = 0
    }
}
