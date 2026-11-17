/// A countdown to the start of recording, such as a race start sequence. Times are
/// seconds on any monotonic or wall clock the caller chooses, as long as it is the same
/// one throughout. The countdown is not part of the session: recording starts when it ends.
public struct StartCountdown: Sendable, Hashable {
    /// When the countdown reaches zero.
    public private(set) var endsAt: Double
    /// The length it started with, s.
    public let duration: Double

    public init(duration: Double, startingAt now: Double) {
        self.duration = max(0, duration)
        endsAt = now + self.duration
    }

    public func remaining(at now: Double) -> Double {
        max(0, endsAt - now)
    }

    public func isFinished(at now: Double) -> Bool {
        remaining(at: now) <= 0
    }

    /// Whole seconds left as shown on a clock: 5:00 at the start, 0:01 during the last
    /// second, 0:00 once finished.
    public func displaySeconds(at now: Double) -> Int {
        let left = remaining(at: now)
        // Tolerate floating-point noise just below a whole second (299.9999999 → 5:00).
        return Int((left - 1e-6).rounded(.up))
    }

    /// Rounds the time left to the nearest whole minute, for matching a start signal
    /// ("sync" at a race start). Under 30 s left rounds to zero and finishes the countdown.
    public mutating func sync(at now: Double) {
        let minutes = (remaining(at: now) / 60).rounded(.toNearestOrAwayFromZero)
        endsAt = now + minutes * 60
    }

    /// A haptic cue for the moment the time left goes from `previous` to `now`.
    public enum Cue: Sendable, Hashable {
        /// A whole minute left (1 or more).
        case minute(Int)
        /// One of the last 10 seconds.
        case second(Int)
        /// Zero: recording starts.
        case start
    }

    /// The most important cue passed between two readings of the clock, or nil. Called on
    /// every tick with the previous tick's time; a gap (the app was suspended) gives at
    /// most one cue rather than a burst.
    public func cue(from previous: Double, to now: Double) -> Cue? {
        let before = remaining(at: previous)
        let after = remaining(at: now)
        guard before > after else { return nil }
        if before > 0, after <= 0 { return .start }
        // Thresholds crossed: before > t >= after.
        let minute = Int((after / 60).rounded(.up))
        if minute >= 1, Double(minute) * 60 < before { return .minute(minute) }
        let second = Int(after.rounded(.up))
        if second >= 1, second <= 10, Double(second) < before { return .second(second) }
        return nil
    }
}

/// Fires every `interval` metres of session distance (the distance alert setting).
public struct DistanceAlert: Sendable, Hashable {
    /// Metres between alerts.
    public let interval: Double
    /// How many alerts have fired.
    public private(set) var count = 0

    public init?(interval: Double?) {
        guard let interval, interval > 0, interval.isFinite else { return nil }
        self.interval = interval
    }

    /// Feeds the session distance, m. Returns the distance of the milestone reached (a
    /// whole multiple of `interval`) when a new one was passed. Distance going down (a
    /// recalculation) never repeats an alert, and a jump past several milestones alerts
    /// once, for the last.
    public mutating func update(distance: Double) -> Double? {
        guard distance.isFinite else { return nil }
        // A small tolerance, so 3 × 0.1 km counts as 300 m.
        let reached = Int((distance / interval + 1e-9).rounded(.down))
        guard reached > count else { return nil }
        count = reached
        return Double(reached) * interval
    }
}
