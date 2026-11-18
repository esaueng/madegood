import Foundation

/// The anchor alarm (docs/PLAN.md §5, docs/metrics.md "Anchor alarm"): an anchor point
/// and a radius, and a state machine that raises an alarm when the boat has left the
/// circle, while ignoring the GPS noise and one-off jumps a boat swinging at anchor sees.
///
/// Times are seconds on any monotonic-enough clock the caller chooses (the app uses unix
/// time, so a saved alarm survives a relaunch). Positions are degrees, distances metres.
///
/// - `clear`: no anchor set.
/// - `armed`: watching; the boat is inside the circle or the evidence is not conclusive.
/// - `alarming(.dragging)`: the boat has been clearly outside the circle for at least
///   `confirmFixes` usable fixes in a row spanning `confirmSeconds`. It latches: coming
///   back inside does not silence it, because a dragging anchor can swing back in.
/// - `alarming(.gpsLost)`: no usable fix for `gpsLostAfter`. The next usable fix clears
///   it (the drag check then decides).
public struct AnchorAlarm: Sendable, Hashable, Codable {
    public struct Config: Sendable, Hashable, Codable {
        /// Fixes with a worse (or unknown) horizontal accuracy are ignored, m.
        public var maxHorizontalAccuracy = 25.0
        /// Clearly-outside fixes needed in a row before alarming.
        public var confirmFixes = 3
        /// ...and the time they must span, s: a short delay that rides out a GPS jump.
        public var confirmSeconds = 10.0
        /// No usable fix for this long raises a GPS alarm, s.
        public var gpsLostAfter = 120.0
        /// After the user silences an alarm, it does not sound again for this long, s.
        public var silenceFor = 60.0

        public init() {}
    }

    public enum Reason: String, Sendable, Hashable, Codable {
        case dragging
        case gpsLost
    }

    public enum State: Sendable, Hashable, Codable {
        case clear
        case armed
        case alarming(Reason)

        public var isAlarming: Bool {
            if case .alarming = self { true } else { false }
        }
    }

    public struct Anchor: Sendable, Hashable, Codable {
        public var latitude: Double
        public var longitude: Double
        /// Alarm radius around the anchor point, m.
        public var radius: Double
        /// When the anchor was set.
        public var setAt: Double

        public init(latitude: Double, longitude: Double, radius: Double, setAt: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.setAt = setAt
        }
    }

    /// Radii offered in the app, m. The radius should cover the scope of rode out plus
    /// the boat's length, or the boat swinging with the wind will trip it.
    public static let radiusChoices: [Double] = [20, 30, 40, 50, 75, 100, 150]
    public static let defaultRadius = 40.0
    public static let radiusRange: ClosedRange<Double> = 10...500

    public var config: Config
    public private(set) var state: State = .clear
    public private(set) var anchor: Anchor?
    /// Distance from the latest usable fix to the anchor, m.
    public private(set) var distance: Double?
    /// Bearing from the latest usable fix to the anchor, degrees true.
    public private(set) var bearing: Double?
    /// The accuracy radius of the latest usable fix, m.
    public private(set) var accuracy: Double?
    /// Farthest usable fix from the anchor since it was set (the swing), m.
    public private(set) var maxDistance: Double?
    /// Time of the latest usable fix.
    public private(set) var lastFixTime: Double?
    /// When the latest silence ends; no alarm sounds before then.
    public private(set) var silencedUntil: Double?

    private var outsideCount = 0
    private var outsideSince: Double?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isArmed: Bool { state != .clear }

    // MARK: - Commands

    /// Sets the anchor at a point and starts watching. Returns false (and changes
    /// nothing) for an invalid point or radius.
    @discardableResult
    public mutating func set(latitude: Double, longitude: Double, radius: Double, at t: Double) -> Bool {
        guard Self.validCoordinate(latitude: latitude, longitude: longitude), Self.validRadius(radius), t.isFinite
        else { return false }
        anchor = Anchor(latitude: latitude, longitude: longitude, radius: radius, setAt: t)
        state = .armed
        distance = nil
        bearing = nil
        accuracy = nil
        maxDistance = nil
        lastFixTime = t
        silencedUntil = nil
        resetEvidence()
        return true
    }

    /// Changes the radius of the anchor already set. The evidence starts again, since
    /// "outside" meant something else before.
    @discardableResult
    public mutating func setRadius(_ radius: Double) -> Bool {
        guard anchor != nil, Self.validRadius(radius) else { return false }
        anchor?.radius = radius
        resetEvidence()
        return true
    }

    /// Raises the anchor: no more watching.
    public mutating func clear() {
        self = AnchorAlarm(config: config)
    }

    /// Acknowledges an alarm: back to armed, quiet for `config.silenceFor`. If the boat is
    /// still outside after that, the alarm sounds again.
    public mutating func silence(at t: Double) {
        guard state.isAlarming, t.isFinite else { return }
        state = .armed
        silencedUntil = t + config.silenceFor
    }

    // MARK: - Input

    /// Feeds one location fix. Fixes out of time order, without a usable accuracy, or
    /// with an invalid position are ignored. Returns true when the state changed.
    @discardableResult
    public mutating func ingest(_ fix: GPSFix) -> Bool {
        guard let anchor, fix.t.isFinite, Self.validCoordinate(latitude: fix.latitude, longitude: fix.longitude),
            let hacc = fix.horizontalAccuracy, hacc.isFinite, hacc >= 0, hacc <= config.maxHorizontalAccuracy
        else { return advance(to: fix.t) }
        if let last = lastFixTime, fix.t < last { return false }
        let before = state
        lastFixTime = fix.t
        let distance = Geo.distance(
            lat1: fix.latitude, lon1: fix.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        self.distance = distance
        bearing = Geo.bearing(lat1: fix.latitude, lon1: fix.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        accuracy = hacc
        maxDistance = max(maxDistance ?? distance, distance)

        if state == .alarming(.gpsLost) { state = .armed }

        // Accuracy-aware hysteresis: "clearly outside" when even the near edge of the
        // accuracy circle is outside; "inside" when the fix itself is inside. In between
        // the fix is inconclusive and leaves the evidence as it was.
        if distance - hacc > anchor.radius {
            outsideCount += 1
            let since = outsideSince ?? fix.t
            outsideSince = since
            if outsideCount >= config.confirmFixes, fix.t - since >= config.confirmSeconds, !isSilenced(at: fix.t) {
                state = .alarming(.dragging)
            }
        } else if distance <= anchor.radius {
            resetEvidence()
        }
        return state != before
    }

    /// Moves the clock forward without a fix, so a silent GPS raises its alarm. Returns
    /// true when the state changed.
    @discardableResult
    public mutating func advance(to t: Double) -> Bool {
        guard state == .armed, t.isFinite, let last = lastFixTime, !isSilenced(at: t),
            t - last >= config.gpsLostAfter
        else { return false }
        state = .alarming(.gpsLost)
        return true
    }

    // MARK: - Helpers

    public func isSilenced(at t: Double) -> Bool {
        silencedUntil.map { t < $0 } ?? false
    }

    /// The anchor point for "drop anchor here": the accuracy-weighted mean of the usable
    /// fixes in the last `window` seconds before the newest one, so one noisy fix does
    /// not misplace the circle. Nil without a usable fix.
    public static func anchorPoint(
        from fixes: [GPSFix], window: Double = 10, maxHorizontalAccuracy: Double = Config().maxHorizontalAccuracy
    ) -> (latitude: Double, longitude: Double)? {
        let usable = fixes.filter { fix in
            fix.t.isFinite && validCoordinate(latitude: fix.latitude, longitude: fix.longitude)
                && (fix.horizontalAccuracy.map { $0.isFinite && $0 >= 0 && $0 <= maxHorizontalAccuracy } ?? false)
        }
        guard let newest = usable.max(by: { $0.t < $1.t }) else { return nil }
        let recent = usable.filter { newest.t - $0.t <= window }
        // Weight by 1/σ² with a floor, so a claimed 0 m accuracy cannot dominate.
        var sumWeight = 0.0
        var north = 0.0
        var east = 0.0
        for fix in recent {
            let sigma = max(fix.horizontalAccuracy ?? 1, 1)
            let weight = 1 / (sigma * sigma)
            // Offsets from the newest fix in metres, which is exact enough over metres.
            let d = Geo.distance(lat1: newest.latitude, lon1: newest.longitude, lat2: fix.latitude, lon2: fix.longitude)
            let b =
                Geo.bearing(lat1: newest.latitude, lon1: newest.longitude, lat2: fix.latitude, lon2: fix.longitude)
                * .pi / 180
            north += weight * d * cos(b)
            east += weight * d * sin(b)
            sumWeight += weight
        }
        north /= sumWeight
        east /= sumWeight
        let offset = (north * north + east * east).squareRoot()
        guard offset > 0 else { return (newest.latitude, newest.longitude) }
        let bearing = atan2(east, north) * 180 / .pi
        let point = Geo.destination(
            lat: newest.latitude, lon: newest.longitude, bearing: (bearing + 360).truncatingRemainder(dividingBy: 360),
            distance: offset)
        return (point.lat, point.lon)
    }

    private mutating func resetEvidence() {
        outsideCount = 0
        outsideSince = nil
    }

    static func validCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func validRadius(_ radius: Double) -> Bool {
        radius.isFinite && radiusRange.contains(radius)
    }
}
