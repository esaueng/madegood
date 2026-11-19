/// The motorboat trip log and fuel estimate (docs/PLAN.md §5, docs/metrics.md
/// "Motorboating"). Distances in metres, times in seconds, fuel in litres.

/// The fuel model: the user's burn rates, applied to engine time and idle time.
///
/// It is an estimate, not a measurement: real burn depends on load, trim, sea state and
/// the engine, none of which the app can see. Show it labeled as an estimate.
public struct FuelModel: Sendable, Hashable {
    /// Burn while under way (at or above `SessionEngine.underWaySpeed`), litres per hour.
    public var burnRate: Double
    /// Burn during the rest of the moving time (idling, slow manoeuvring), litres per
    /// hour. 0 when the engine is off while stopped.
    public var idleBurnRate: Double

    public init(burnRate: Double, idleBurnRate: Double = 0) {
        self.burnRate = burnRate
        self.idleBurnRate = idleBurnRate
    }

    /// Valid rates are finite and not negative; the under-way rate must be positive.
    public var isValid: Bool {
        burnRate.isFinite && burnRate > 0 && idleBurnRate.isFinite && idleBurnRate >= 0
    }

    /// The estimate for a session's metrics, or nil when the rates are not valid.
    public func estimate(_ metrics: LiveMetrics) -> FuelEstimate? {
        estimate(underWayTime: metrics.underWayTime, movingTime: metrics.movingTime)
    }

    /// The estimate for `underWayTime` out of `movingTime` (both s). The rest of the
    /// moving time is idle time.
    public func estimate(underWayTime: Double, movingTime: Double) -> FuelEstimate? {
        guard isValid, underWayTime.isFinite, movingTime.isFinite else { return nil }
        let engine = max(0, underWayTime)
        let idle = max(0, movingTime - engine)
        let litres = (burnRate * engine + idleBurnRate * idle) / 3600
        return FuelEstimate(litres: litres, engineTime: engine, idleTime: idle)
    }
}

/// An estimated fuel use and the times it was computed from.
public struct FuelEstimate: Sendable, Hashable {
    public var litres: Double
    /// Time under way, s.
    public var engineTime: Double
    /// Moving time not under way, s.
    public var idleTime: Double
}

/// The nautical-mile log: this trip and the running total over motorboat trips.
public struct NauticalLog: Sendable, Hashable {
    /// One saved trip: when it started (unix time, s) and its distance, m.
    public struct Trip: Sendable, Hashable {
        public var startedAt: Double
        public var distance: Double

        public init(startedAt: Double, distance: Double) {
            self.startedAt = startedAt
            self.distance = distance
        }
    }

    /// This trip's distance, m.
    public var trip: Double
    /// Every earlier trip plus this one, m.
    public var total: Double

    /// The log for a trip in progress: `trip` on top of every saved trip.
    public init(trip: Double, saved: [Trip]) {
        self.trip = Self.clean(trip)
        total = Self.sum(saved) + self.trip
    }

    /// The log for a saved trip: its distance, and that plus every saved trip that
    /// started before it. `saved` may include the trip itself (in any version: its
    /// summary can still be updating); only earlier start times are added.
    public init(savedTrip: Trip, all saved: [Trip]) {
        trip = Self.clean(savedTrip.distance)
        total = Self.sum(saved.filter { $0.startedAt.isFinite && $0.startedAt < savedTrip.startedAt }) + trip
    }

    private static func clean(_ distance: Double) -> Double {
        distance.isFinite && distance > 0 ? distance : 0
    }

    private static func sum(_ trips: [Trip]) -> Double {
        trips.reduce(0) { $0 + clean($1.distance) }
    }
}
