import Foundation

/// The anchor alarm (docs/PLAN.md §5, docs/metrics.md "Anchor alarm"): an anchor point
/// and a radius, and a state machine that raises an alarm when the boat has left the
/// circle, while ignoring the GPS noise and one-off jumps a boat swinging at anchor sees.
///
/// Times are seconds on a monotonic clock the caller chooses (the app uses the time each
/// fix arrived on `ProcessInfo.systemUptime`), so a change to the wall clock can neither
/// fake a GPS gap nor make fixes look out of order. Such a clock restarts with the
/// process, so a saved alarm is moved onto the new clock with `resume(at:)`.
/// Positions are degrees, distances metres.
///
/// - `clear`: no anchor set.
/// - `armed`: watching; the boat is inside the circle or the evidence is not conclusive.
/// - `alarming(.dragging)`: the boat has been clearly outside the circle for at least
///   `confirmFixes` clearly-outside fixes spanning `confirmSeconds`, all within the last
///   `evidenceWindow` and with no inside fix since the first of them. It latches: coming
///   back inside does not silence it, because a dragging anchor can swing back in.
/// - `alarming(.gpsLost)`: no usable fix for `gpsLostAfter`, noticed either by the clock
///   (`advance`) or by a fix that arrives after such a gap (the app was suspended). The
///   next usable fix after that clears it (the drag check then decides).
public struct AnchorAlarm: Sendable, Hashable, Codable {
    public struct Config: Sendable, Hashable, Codable {
        /// Fixes with a worse (or unknown) horizontal accuracy are ignored, m.
        public var maxHorizontalAccuracy = 25.0
        /// Clearly-outside fixes needed before alarming.
        public var confirmFixes = 3
        /// ...the time they must span, s: a short delay that rides out a GPS jump...
        public var confirmSeconds = 10.0
        /// ...and the window they must all fall in, s. Older outside readings expire, so
        /// two separate excursions are never joined into one drag.
        public var evidenceWindow = 15.0
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
    /// When the current alarm started; nil unless alarming.
    public private(set) var alarmingSince: Double?

    /// Times of the clearly-outside fixes since the last inside fix, within the window.
    private var outsideTimes: [Double] = []

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
        alarmingSince = nil
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
        alarmingSince = nil
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
        // A fix after a long silence (the app was suspended) first raises the GPS alarm
        // the clock would have raised, so the gap is never hidden by the fix that ends it.
        let gapAlarm = gpsLostDeadline.map { fix.t >= $0 } ?? false
        if gapAlarm { raise(.gpsLost, at: fix.t) }
        lastFixTime = fix.t
        let distance = Geo.distance(
            lat1: fix.latitude, lon1: fix.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        self.distance = distance
        bearing = Geo.bearing(lat1: fix.latitude, lon1: fix.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
        accuracy = hacc
        maxDistance = max(maxDistance ?? distance, distance)

        if state == .alarming(.gpsLost), !gapAlarm {
            state = .armed
            alarmingSince = nil
        }

        // Accuracy-aware evidence. "Clearly outside": even the near edge of the accuracy
        // circle is outside. "Inside": the fix itself is inside, which clears the
        // evidence. Anything else is inconclusive and neither counts nor clears, so one
        // noisy fix cannot hide a drag; the window keeps separate excursions apart.
        if distance - hacc > anchor.radius {
            outsideTimes.append(fix.t)
            outsideTimes.removeAll { fix.t - $0 > config.evidenceWindow }
            if state == .armed, outsideTimes.count >= config.confirmFixes,
                let first = outsideTimes.first, fix.t - first >= config.confirmSeconds, !isSilenced(at: fix.t)
            {
                raise(.dragging, at: fix.t)
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
        raise(.gpsLost, at: t)
        return true
    }

    /// Moves a saved alarm onto a new process's clock at `t`, without trusting how much
    /// time passed (the wall clock may have changed): GPS counts as fresh from `t` (a grace
    /// period before "no GPS"; the app's pending notification covered the time it was not
    /// running), the drag evidence and any silence start over, and a restored alarm keeps
    /// sounding with its repeats counted from `t`.
    public mutating func resume(at t: Double) {
        guard state != .clear, t.isFinite else { return }
        anchor?.setAt = t
        lastFixTime = t
        silencedUntil = nil
        resetEvidence()
        if state.isAlarming { alarmingSince = t }
    }

    /// When the GPS alarm will sound if no usable fix arrives: a deadline for a
    /// dead-man's-switch notification that works while the app is suspended. Nil unless
    /// armed and not alarming.
    public var gpsLostDeadline: Double? {
        guard state == .armed, let last = lastFixTime else { return nil }
        return max(last + config.gpsLostAfter, silencedUntil ?? -.infinity)
    }

    private mutating func raise(_ reason: Reason, at t: Double) {
        state = .alarming(reason)
        alarmingSince = t
    }

    // MARK: - Helpers

    public func isSilenced(at t: Double) -> Bool {
        silencedUntil.map { t < $0 } ?? false
    }

    /// The anchor point for "drop anchor here": the accuracy-weighted mean of the usable
    /// fixes (accuracy ≤ 25 m) measured in the `window` seconds up to `now`, so one noisy
    /// fix does not misplace the circle and an old position is never used. Nil when no
    /// usable fix is that recent: the anchor cannot be set yet.
    public static func anchorPoint(
        from fixes: [GPSFix], at now: Double, window: Double = 10,
        maxHorizontalAccuracy: Double = Config().maxHorizontalAccuracy
    ) -> (latitude: Double, longitude: Double)? {
        guard now.isFinite else { return nil }
        let recent = fixes.filter { fix in
            fix.t.isFinite && now - fix.t <= window && fix.t <= now + 1
                && validCoordinate(latitude: fix.latitude, longitude: fix.longitude)
                && (fix.horizontalAccuracy.map { $0.isFinite && $0 >= 0 && $0 <= maxHorizontalAccuracy } ?? false)
        }
        guard let newest = recent.max(by: { $0.t < $1.t }) else { return nil }
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
        outsideTimes.removeAll()
    }

    static func validCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func validRadius(_ radius: Double) -> Bool {
        radius.isFinite && radiusRange.contains(radius)
    }
}

/// The alerts an armed anchor alarm needs, as local notifications that fire even when
/// the app is suspended or terminated: a dead-man's switch for lost GPS while armed, and
/// while alarming, near-term repeats every 30 s plus one repeating notification every
/// 60 s that never runs out until the app silences or raises the alarm. Every identifier
/// comes from the fixed set `allIDs`, so the app can cancel them all without knowing what
/// an earlier process scheduled.
public enum AnchorAlertSchedule {
    public struct Alert: Sendable, Hashable {
        public var id: String
        /// First firing, on the alarm's clock.
        public var fireAt: Double
        public var reason: AnchorAlarm.Reason
        /// Fires again every this many seconds until removed; nil fires once.
        public var repeatsEvery: Double? = nil
    }

    /// While alarming, one-shot alerts repeat this often, s, with this many kept pending.
    public static let repeatInterval = 30.0
    public static let repeatCount = 20
    /// The repeating notification's period, s (iOS requires at least 60).
    public static let repeatingInterval = 60.0

    public static let gpsLostID = "anchorAlarm.gpsLost"
    public static let repeatingID = "anchorAlarm.repeating"
    /// The immediate alert the app posts when an alarm starts in the background.
    public static let nowID = "anchorAlarm.now"
    /// One-shot repeat `index` uses slot `index % repeatCount`.
    public static func repeatID(_ index: Int) -> String { "anchorAlarm.repeat.\(index % repeatCount)" }
    /// Every identifier this schedule or the app ever uses.
    public static let allIDs: [String] =
        [gpsLostID, repeatingID, nowID] + (0..<repeatCount).map { "anchorAlarm.repeat.\($0)" }

    /// The notifications that should be pending at `now`.
    public static func pending(for alarm: AnchorAlarm, now: Double) -> [Alert] {
        switch alarm.state {
        case .clear:
            return []
        case .armed:
            guard let deadline = alarm.gpsLostDeadline else { return [] }
            return [Alert(id: gpsLostID, fireAt: max(deadline, now + 1), reason: .gpsLost)]
        case .alarming(let reason):
            // The next `repeatCount` slots on the alarm's 30 s cadence, so an alarm
            // restored long after it started still has repeats ahead of it.
            let since = alarm.alarmingSince ?? now
            let first = max(1, Int(((now - since) / repeatInterval).rounded(.down)) + 1)
            let repeats = (first..<(first + repeatCount)).map { index in
                Alert(id: repeatID(index), fireAt: since + Double(index) * repeatInterval, reason: reason)
            }
            let forever = Alert(
                id: repeatingID, fireAt: since + repeatingInterval, reason: reason, repeatsEvery: repeatingInterval)
            return repeats + [forever]
        }
    }

    /// Whether an in-app alert (sound and haptics) is due: always for an alarm with no
    /// alert yet in this process (including one restored after a relaunch), then every
    /// `repeatInterval`.
    public static func isAlertDue(alarm: AnchorAlarm, lastAlert: Double?, now: Double) -> Bool {
        guard alarm.state.isAlarming else { return false }
        guard let lastAlert else { return true }
        return now - lastAlert >= repeatInterval
    }
}
