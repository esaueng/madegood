import Foundation

/// Watches a swing circle. Distances (including horizontal accuracy) are in metres,
/// bearings in degrees true, and fix timestamps in seconds on the caller's monotonic clock.
public struct AnchorAlarm: Sendable {
    public static let maximumAccuracy = 25.0
    // Treat optimistic GPS estimates as at least this uncertain near the boundary.
    private static let minimumOutsideAccuracy = 5.0
    public static let confirmationFixCount = 3
    public static let snoozeDuration = 120.0
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
    private var outsideCount = 0

    public init?(anchor: Point, radius: Double, confirmedOutside: Bool = false) {
        guard Self.radiusRange.contains(radius),
            Point(latitude: anchor.latitude, longitude: anchor.longitude) != nil
        else { return nil }
        self.anchor = anchor
        self.radius = radius
        isDrifting = confirmedOutside
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
        reading(at: boat).distance - max(accuracy, Self.minimumOutsideAccuracy) > radius
    }

    /// Returns true when a run first confirms drift.
    @discardableResult
    public mutating func ingest(_ fix: GPSFix) -> Bool {
        assess(fix) == .driftConfirmed
    }

    /// A confidently inside fix clears drift and outside evidence. Uncertain
    /// and unusable fixes leave the evidence intact, including across GPS gaps.
    public mutating func assess(_ fix: GPSFix) -> FixAssessment {
        guard fix.t.isFinite, lastFixTime.map({ fix.t > $0 }) ?? true,
            let boat = Point(latitude: fix.latitude, longitude: fix.longitude),
            let accuracy = fix.horizontalAccuracy, (0...Self.maximumAccuracy).contains(accuracy)
        else { return .unusable }
        lastFixTime = fix.t
        let distance = reading(at: boat).distance
        guard distance - max(accuracy, Self.minimumOutsideAccuracy) > radius else {
            if distance + accuracy < radius {
                isDrifting = false
                outsideCount = 0
            }
            return .withinOrUncertain
        }
        guard !isDrifting else { return .outside }
        outsideCount += 1
        isDrifting = outsideCount == Self.confirmationFixCount
        return isDrifting ? .driftConfirmed : .outside
    }

    public func snoozeDeadline(afterStopAt time: Double) -> Double? {
        isDrifting ? time + Self.snoozeDuration : nil
    }
}
