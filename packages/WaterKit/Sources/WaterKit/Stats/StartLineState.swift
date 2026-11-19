import Foundation

/// The start line's state across a sailing countdown and the race start (docs/metrics.md,
/// "Start line"): the pinged ends, a ping being averaged, whether a saved line belongs
/// to this venue, and the start check at the gun. The apps wrap it; every time here is
/// on the fixes' clock (unix s in the apps), except `OCSWarning.shownAt`, which is on
/// whatever monotonic clock the caller passes.
public struct StartLineState: Sendable {
    /// A line is kept this long after its last ping, s.
    public static let keepsLineFor = 6 * 3600.0
    /// A saved line is reused only within this distance of its middle, m.
    public static let reuseRadius = 2_000.0
    /// The start check needs a fix within this long of the gun, s.
    public static let gunFixMaxAge = 2.0
    /// A fix without an accuracy is taken as this good for the start check's margin, m.
    public static let assumedAccuracy = 10.0
    /// The start warning clears itself after this long, s.
    public static let warningShownFor = 300.0

    public private(set) var pin: StartLinePing?
    public private(set) var boat: StartLinePing?
    /// The ping being averaged.
    public private(set) var pending: StartLinePingAverager?
    /// The last ping found no usable fix.
    public private(set) var lastPingFailed: StartLineEnd?
    /// The saved line was checked against a position at this venue (or there was none).
    public private(set) var isVerified = true
    /// Ends pinged during this countdown: known to be here.
    private var pingedNow: Set<StartLineEnd> = []
    public private(set) var warning: OCSWarning?

    public init(pin: StartLinePing? = nil, boat: StartLinePing? = nil) {
        self.pin = pin
        self.boat = boat
    }

    public var line: StartLine? {
        guard let pin, let boat else { return nil }
        return StartLine(pin: pin, boat: boat)
    }

    public func ping(_ end: StartLineEnd) -> StartLinePing? { end == .pin ? pin : boat }

    /// When the line was last pinged, on the fixes' clock.
    public var lastPingTime: Double? { [pin?.time, boat?.time].compactMap { $0 }.max() }

    /// Whether the line has outlived `keepsLineFor` at `now`.
    public func isExpired(now: Double) -> Bool {
        guard let last = lastPingTime else { return false }
        return now - last > Self.keepsLineFor
    }

    /// Pings to record with a session at `now`, in time order: every end once the line is
    /// known to be at this venue, else only the ends pinged in this countdown; none once
    /// the line has expired.
    public func pingsToRecord(now: Double) -> [StartLinePing] {
        guard !isExpired(now: now) else { return [] }
        return [pin, boat].compactMap { $0 }
            .filter { isVerified || pingedNow.contains($0.end) }
            .sorted { $0.time < $1.time }
    }

    /// The line to use at `now` for readings and the start check: nil once expired, and
    /// until a saved line has been matched to this venue.
    public func usableLine(now: Double) -> StartLine? {
        guard let line, !isExpired(now: now) else { return nil }
        return isVerified || pingedNow.isSuperset(of: [.pin, .boat]) ? line : nil
    }

    // MARK: Lifetime

    /// Drops the whole line `keepsLineFor` after its last ping. Returns whether it did.
    @discardableResult
    public mutating func expire(now: Double) -> Bool {
        guard isExpired(now: now) else { return false }
        pin = nil
        boat = nil
        pingedNow = []
        return true
    }

    /// A countdown began at `now`: expire an old line and ask for a saved one to be
    /// matched to the first position before it is used.
    public mutating func countdownBegan(now: Double) {
        expire(now: now)
        warning = nil
        pending = nil
        lastPingFailed = nil
        pingedNow = []
        isVerified = pin == nil && boat == nil
    }

    /// Feeds a position: matches a saved line to this venue (dropping it when it is more
    /// than `reuseRadius` from the line's middle, or from a lone end), and adds the fix to
    /// a ping being averaged. Returns whether a saved line was dropped.
    /// `toPing: false` keeps the fix out of a pending ping (the demo feed pings fixed ends).
    @discardableResult
    public mutating func add(_ fix: GPSFix, toPing: Bool = true) -> Bool {
        if toPing { pending?.add(fix) }
        guard !isVerified else { return false }
        isVerified = true
        let ends = [pin, boat].compactMap { $0 }.filter { !pingedNow.contains($0.end) }
        guard !ends.isEmpty else { return false }
        let points = ends.map { SphereVector(latitude: $0.latitude, longitude: $0.longitude) }
        let sum = points.reduce(SphereVector(x: 0, y: 0, z: 0)) {
            SphereVector(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        guard let middle = sum.normalized else { return false }
        let distance = Geo.distance(
            lat1: middle.latitude, lon1: middle.longitude, lat2: fix.latitude, lon2: fix.longitude)
        guard distance > Self.reuseRadius else { return false }
        for end in ends.map(\.end) {
            if end == .pin { pin = nil } else { boat = nil }
        }
        return true
    }

    // MARK: Pings

    /// Starts averaging a ping of `end` pressed at `time`. Ignored while one is pending.
    public mutating func startPing(_ end: StartLineEnd, at time: Double, recentFixes: [GPSFix] = []) {
        guard pending == nil else { return }
        var averager = StartLinePingAverager(end: end, pressedAt: time)
        for fix in recentFixes { averager.add(fix) }
        pending = averager
        lastPingFailed = nil
    }

    /// Finishes the pending ping with the fixes it has. Returns the ping, or nil when it
    /// had no usable fix (then `lastPingFailed` is set) or nothing was pending.
    @discardableResult
    public mutating func finishPing() -> StartLinePing? {
        guard let averager = pending else { return nil }
        pending = nil
        guard let ping = averager.ping else {
            lastPingFailed = averager.end
            return nil
        }
        if ping.end == .pin { pin = ping } else { boat = ping }
        pingedNow.insert(ping.end)
        return ping
    }

    public mutating func clear() {
        pin = nil
        boat = nil
        pending = nil
        pingedNow = []
        isVerified = true
    }

    // MARK: The gun

    /// The countdown reached zero at `time` with `latest` the newest fix. A pending ping
    /// is finished first with the fixes it has, so it counts and is recorded. Returns the
    /// start check, nil without a usable line. `shownAt` stamps any warning.
    @discardableResult
    public mutating func gun(at time: Double, latest: GPSFix?, shownAt: Double) -> StartCheck? {
        finishPing()
        expire(now: time)
        guard let line = usableLine(now: time) else { return nil }
        let check = Self.check(line: line, at: time, latest: latest)
        switch check {
        case .clear: warning = nil
        case .over, .possiblyOver, .unknown: warning = OCSWarning(check: check, shownAt: shownAt)
        }
        return check
    }

    /// Where the boat was at `time`: the newest fix moved to that time along its Doppler
    /// speed and course, as long as it is within `gunFixMaxAge` of it.
    public static func check(line: StartLine, at time: Double, latest: GPSFix?) -> StartCheck {
        guard let fix = latest, abs(time - fix.t) <= gunFixMaxAge,
            let moved = StartLinePingAverager.project(fix, to: time)
        else { return .unknown }
        let place = line.position(
            latitude: moved.latitude, longitude: moved.longitude, speed: fix.speed, course: fix.course)
        if place.isOver { return .over(distance: -place.distance) }
        let accuracy = fix.horizontalAccuracy ?? assumedAccuracy
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
}

/// The start check at the gun.
public enum StartCheck: Sendable, Hashable {
    /// Behind the line by `distance` m.
    case clear(distance: Double)
    /// Behind, but closer than the fix's accuracy and heading for the line.
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
