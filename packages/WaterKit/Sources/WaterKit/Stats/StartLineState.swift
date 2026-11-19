import Foundation

/// The start line's state across a sailing countdown and the race start (docs/metrics.md,
/// "Start line"): the pinged ends, a ping being averaged, whether saved ends belong to
/// this venue, and the start check at the gun. The apps wrap it. Every time here is on
/// the countdown's clock (`CountdownClock`: unix s, anchored to a monotonic clock), except
/// `OCSWarning.shownAt`, which is on whatever monotonic clock the caller passes.
public struct StartLineState: Sendable {
    /// A line is kept this long after its last ping, s.
    public static let keepsLineFor = 6 * 3600.0
    /// A saved end is reused only within this distance of a current position, m.
    public static let reuseRadius = 2_000.0
    /// A position decides about saved ends only if it is this recent, s, and at least
    /// this accurate, m: a cached or rough fix never does.
    public static let venueFixMaxAge = 5.0
    public static let venueFixMaxAccuracy = 25.0
    /// The start check needs a fix within this long before the gun, s.
    public static let gunFixMaxAge = 2.0
    /// A fix stamped up to this long after the gun still counts as at the gun, s.
    public static let gunFixTolerance = 0.25
    /// A fix without an accuracy is taken as this good for the start check's margin, m.
    public static let assumedAccuracy = 10.0
    /// The start warning clears itself after this long, s.
    public static let warningShownFor = 300.0
    /// A ping that failed this soon before the gun is reported again after it, s: the
    /// countdown screen that showed the failure is gone.
    public static let recentFailureWindow = 15.0

    private var pins: [StartLineEnd: StartLinePing] = [:]
    /// The ping being averaged.
    public private(set) var pending: StartLinePingAverager?
    /// The last ping found too few usable fixes, and when it was pressed.
    public private(set) var lastPingFailed: StartLineEnd?
    private var lastPingFailedAt: Double?
    /// Ends pinged during this countdown: known to be here.
    private var pingedNow: Set<StartLineEnd> = []
    /// Saved ends a fresh position put near the boat, and ones it put far away (ignored
    /// for this countdown, still saved).
    private var matched: Set<StartLineEnd> = []
    private var ignored: Set<StartLineEnd> = []
    public private(set) var warning: OCSWarning?
    /// A ping that failed at the gun or shortly before it, for the session screens.
    public private(set) var failedAtStart: StartLineEnd?

    public init(pin: StartLinePing? = nil, boat: StartLinePing? = nil) {
        pins[.pin] = pin
        pins[.boat] = boat
    }

    /// Every stored end, active or not (for saving).
    public func stored(_ end: StartLineEnd) -> StartLinePing? { pins[end] }

    /// An end in use: pinged in this countdown, or saved and matched to this venue.
    public func ping(_ end: StartLineEnd) -> StartLinePing? {
        guard let ping = pins[end], pingedNow.contains(end) || matched.contains(end) else { return nil }
        return ping
    }

    public var pin: StartLinePing? { ping(.pin) }
    public var boat: StartLinePing? { ping(.boat) }

    /// The line between the ends in use.
    public var line: StartLine? {
        guard let pin, let boat else { return nil }
        return StartLine(pin: pin, boat: boat)
    }

    /// Saved ends still waiting for a fresh position to say whether they are here.
    public var isAwaitingVenue: Bool {
        pins.keys.contains { !pingedNow.contains($0) && !matched.contains($0) && !ignored.contains($0) }
    }

    /// When the line was last pinged.
    public var lastPingTime: Double? { pins.values.map(\.time).max() }

    /// Whether the line has outlived `keepsLineFor` at `now`.
    public func isExpired(now: Double) -> Bool {
        guard let last = lastPingTime else { return false }
        return now - last > Self.keepsLineFor
    }

    /// Pings to record with a session at `now`, in time order: the ends in use, none once
    /// the line has expired.
    public func pingsToRecord(now: Double) -> [StartLinePing] {
        guard !isExpired(now: now) else { return [] }
        return [pin, boat].compactMap { $0 }.sorted { $0.time < $1.time }
    }

    /// The line to use at `now` for readings and the start check.
    public func usableLine(now: Double) -> StartLine? {
        isExpired(now: now) ? nil : line
    }

    // MARK: Lifetime

    /// Drops the whole line `keepsLineFor` after its last ping. Returns whether it did.
    @discardableResult
    public mutating func expire(now: Double) -> Bool {
        guard isExpired(now: now) else { return false }
        pins = [:]
        pingedNow = []
        matched = []
        ignored = []
        return true
    }

    /// A countdown began at `now`: expire an old line, and hold saved ends back until a
    /// fresh position matches them to this venue.
    public mutating func countdownBegan(now: Double) {
        expire(now: now)
        warning = nil
        failedAtStart = nil
        pending = nil
        lastPingFailed = nil
        lastPingFailedAt = nil
        pingedNow = []
        matched = []
        ignored = []
    }

    /// Feeds a position at `now`: adds it to a pending ping, and lets a fresh, accurate one
    /// decide about saved ends (within `reuseRadius`: used; farther: ignored for this
    /// countdown). `toPing: false` keeps it out of the ping (the demo pings fixed ends).
    public mutating func add(_ fix: GPSFix, now: Double, toPing: Bool = true) {
        if toPing { pending?.add(fix) }
        guard isAwaitingVenue, fix.latitude.isFinite, fix.longitude.isFinite,
            now - fix.t <= Self.venueFixMaxAge, fix.t - now <= 1,
            let accuracy = fix.horizontalAccuracy, accuracy >= 0, accuracy <= Self.venueFixMaxAccuracy
        else { return }
        for (end, ping) in pins where !pingedNow.contains(end) && !matched.contains(end) && !ignored.contains(end) {
            let distance = Geo.distance(
                lat1: ping.latitude, lon1: ping.longitude, lat2: fix.latitude, lon2: fix.longitude)
            if distance <= Self.reuseRadius { matched.insert(end) } else { ignored.insert(end) }
        }
    }

    // MARK: Pings

    /// Starts averaging a ping of `end` pressed at `time`. Ignored while one is pending.
    public mutating func startPing(_ end: StartLineEnd, at time: Double, recentFixes: [GPSFix] = []) {
        guard pending == nil else { return }
        expire(now: time)
        var averager = StartLinePingAverager(end: end, pressedAt: time)
        for fix in recentFixes { averager.add(fix) }
        pending = averager
        lastPingFailed = nil
        lastPingFailedAt = nil
    }

    /// Finishes the pending ping with the fixes it has. Returns the ping, or nil when it
    /// had fewer than `StartLinePingAverager.minimumFixes` (then `lastPingFailed` is set)
    /// or nothing was pending. An expired line is dropped first, so a new ping never
    /// revives an old end.
    @discardableResult
    public mutating func finishPing() -> StartLinePing? {
        guard let averager = pending else { return nil }
        pending = nil
        expire(now: averager.pressedAt)
        guard let ping = averager.ping else {
            lastPingFailed = averager.end
            lastPingFailedAt = averager.pressedAt
            return nil
        }
        pins[ping.end] = ping
        pingedNow.insert(ping.end)
        ignored.remove(ping.end)
        return ping
    }

    public mutating func clear() {
        pins = [:]
        pending = nil
        pingedNow = []
        matched = []
        ignored = []
    }

    // MARK: The gun

    /// The countdown reached zero at `time` (its deadline, on the countdown's clock).
    /// The line's expiry is checked first, then a pending ping is finished with the fixes
    /// it has, so it counts and is recorded. `fixes` are the recent positions; the newest
    /// at or before the gun is used. Returns the start check, nil without a usable line.
    /// `shownAt` stamps any warning.
    @discardableResult
    public mutating func gun(at time: Double, fixes: [GPSFix], shownAt: Double) -> StartCheck? {
        expire(now: time)
        let hadPending = pending?.end
        finishPing()
        failedAtStart = nil
        if let failed = lastPingFailed, let at = lastPingFailedAt,
            hadPending == failed || time - at <= Self.recentFailureWindow
        {
            failedAtStart = failed
        }
        guard let line = usableLine(now: time) else { return nil }
        let check = Self.check(line: line, at: time, fixes: fixes)
        switch check {
        case .clear: warning = nil
        case .over, .possiblyOver, .unknown: warning = OCSWarning(check: check, shownAt: shownAt)
        }
        return check
    }

    /// Where the boat was at `time`: the newest fix stamped at or before it (within
    /// `gunFixTolerance`) and no more than `gunFixMaxAge` older, moved to `time` along its
    /// Doppler speed and course when it is fast enough to trust them.
    public static func check(line: StartLine, at time: Double, fixes: [GPSFix]) -> StartCheck {
        let candidates = fixes.filter { $0.t <= time + gunFixTolerance && time - $0.t <= gunFixMaxAge }
        guard let fix = candidates.max(by: { $0.t < $1.t }),
            let moved = StartLinePingAverager.project(fix, to: time)
        else { return .unknown }
        let place = line.position(
            latitude: moved.latitude, longitude: moved.longitude, speed: fix.speed, course: fix.course)
        let accuracy = fix.horizontalAccuracy ?? assumedAccuracy
        let moving = (fix.speed ?? 0) >= StartLine.minimumSpeed && fix.course != nil
        // Too slow to trust course: never a definite call within GPS error of the line.
        if !moving, abs(place.distance) < accuracy { return .possiblyOver(distance: place.distance) }
        if place.isOver { return .over(distance: -place.distance) }
        if place.distance < accuracy, (place.closingSpeed ?? 0) > 0 {
            return .possiblyOver(distance: place.distance)
        }
        return .clear(distance: place.distance)
    }

    /// Fed with recorded fixes after the start: an over (or possibly over) warning clears
    /// once the boat is back behind the line by more than the fix's accuracy.
    public mutating func recorded(_ fix: GPSFix) {
        guard let warning, let line else { return }
        switch warning.check {
        case .over, .possiblyOver:
            let place = line.position(latitude: fix.latitude, longitude: fix.longitude)
            if place.distance > max(0, fix.horizontalAccuracy ?? 0) { self.warning = nil }
        case .clear, .unknown: break
        }
    }

    /// Clears the warning once it has been shown `warningShownFor` (`now` on the
    /// `shownAt` clock). Returns whether it did.
    @discardableResult
    public mutating func expireWarning(now: Double) -> Bool {
        guard let warning, now - warning.shownAt >= Self.warningShownFor else { return false }
        self.warning = nil
        return true
    }

    public mutating func dismissWarning() { warning = nil }

    public mutating func dismissFailedAtStart() { failedAtStart = nil }
}

/// The start check at the gun.
public enum StartCheck: Sendable, Hashable {
    /// Behind the line by `distance` m.
    case clear(distance: Double)
    /// Within GPS error of the line: `distance` m behind it (negative: over), too close or
    /// too slow to call.
    case possiblyOver(distance: Double)
    /// Over by `distance` m.
    case over(distance: Double)
    /// No fix close enough to the gun to tell.
    case unknown
}

/// A start warning shown after the gun.
public struct OCSWarning: Sendable, Hashable {
    public var check: StartCheck
    /// When it was shown, on the caller's clock.
    public var shownAt: Double

    public init(check: StartCheck, shownAt: Double) {
        self.check = check
        self.shownAt = shownAt
    }
}

/// The countdown's clock: wall-clock (unix) seconds derived from the monotonic uptime
/// through one anchor taken when the countdown starts, so a change to the device clock
/// during the countdown moves neither the gun nor the age of a fix.
public struct CountdownClock: Sendable, Hashable {
    public var anchorUnix: Double
    public var anchorUptime: Double

    public init(unix: Double, uptime: Double) {
        anchorUnix = unix
        anchorUptime = uptime
    }

    /// Unix time of an uptime instant (such as the countdown's deadline).
    public func unix(atUptime uptime: Double) -> Double { anchorUnix + (uptime - anchorUptime) }

    /// A fix's time on this clock. `fixTime` is its own (wall-clock) timestamp,
    /// `receivedUptime` and `receivedWall` the two clocks read when it arrived: their
    /// difference from the timestamp is the fix's age on arrival, which a clock change
    /// does not alter.
    public func fixTime(_ fixTime: Double, receivedUptime: Double, receivedWall: Double) -> Double {
        unix(atUptime: receivedUptime) - max(0, receivedWall - fixTime)
    }
}
