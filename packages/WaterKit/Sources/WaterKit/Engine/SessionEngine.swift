import Foundation

/// A causal analyzer that runs on the device during a session (docs/PLAN.md §4.3).
/// Samples arrive in time order per stream; `snapshot` is cheap to read after each one.
public protocol LiveAnalyzer: Sendable {
    associatedtype Metrics: Sendable
    mutating func ingest(_ sample: Sample)
    var snapshot: Metrics { get }
}

/// One lap of a session. Times are seconds since the session start; distances in metres.
public struct Lap: Sendable, Hashable, Codable {
    /// 1-based.
    public var index: Int
    public var start: Double
    public var end: Double
    public var movingTime: Double
    public var distance: Double
    /// True when the lap was closed by the distance auto-lap rather than by the user.
    public var isAuto: Bool

    public var duration: Double { end - start }
    /// Distance over moving time, m/s; nil before any moving time.
    public var averageSpeed: Double? { movingTime > 0 ? distance / movingTime : nil }
}

/// Sport-independent live metrics. All values SI; convert only for display.
public struct LiveMetrics: Sendable, Hashable {
    public enum PauseState: String, Sendable, Hashable, Codable {
        case moving, autoPaused, manuallyPaused
    }

    /// Time since the session start to the latest sample, s.
    public var elapsed: Double
    /// Time not paused, s. See docs/metrics.md, "Moving time".
    public var movingTime: Double
    /// Distance while not paused, m.
    public var distance: Double
    /// Moving time spent under way: intervals whose Doppler speed is at least
    /// `SessionEngine.underWaySpeed`, s. Motorboating reports it as engine time.
    public var underWayTime: Double = 0
    /// Mean Doppler speed over the last few seconds, m/s.
    public var speed: Double?
    /// Distance over moving time, m/s.
    public var averageSpeed: Double?
    /// Best time-weighted mean Doppler speeds over 2 s and 10 s windows ending at a fix, m/s.
    public var maxSpeed2s: Double? {
        didSet {
            if maxSpeed2s != oldValue { maxSpeed2sRange = nil }
        }
    }
    public var maxSpeed10s: Double? {
        didSet {
            if maxSpeed10s != oldValue { maxSpeed10sRange = nil }
        }
    }
    /// Winning window bounds in seconds since session start. The start may be between
    /// fixes. Exact ties keep the earliest window. Nil when there is no winning window
    /// or the corresponding speed has been overridden.
    public fileprivate(set) var maxSpeed2sRange: ClosedRange<Double>? = nil
    /// The 10 s winning window, with the same time and tie conventions as `maxSpeed2sRange`.
    public fileprivate(set) var maxSpeed10sRange: ClosedRange<Double>? = nil
    /// Smoothed course over ground, degrees true.
    public var course: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var heartRate: Double?
    public var heartRateAverage: Double?
    public var heartRateMax: Double?
    public var pauseState: PauseState
    /// Closed laps, oldest first.
    public var laps: [Lap]
    /// The lap in progress, closed at the latest sample.
    public var currentLap: Lap
    public var acceptedFixes: Int
    public var rejectedFixes: Int
    public var isFinished: Bool
}

/// The sport-independent live session engine: GPS cleaning, auto-pause, laps and the
/// headline metrics. Sport analyzers (strokes, maneuvers) build on top of it.
public struct SessionEngine: LiveAnalyzer {
    /// Window for the displayed current speed, s.
    public static let currentSpeedWindow = 3.0
    /// Windows for the live maximum speeds, s.
    public static let maxSpeedWindows = (short: 2.0, long: 10.0)
    /// The current speed is blanked when the last fix with a speed is older than this, s.
    public static let staleSpeedAfter = 5.0
    /// An interval counts toward `underWayTime` at or above this mean Doppler speed, m/s
    /// (about 1.9 kn): faster than drifting or swinging at anchor.
    public static let underWaySpeed = 1.0

    public let profile: SportProfile
    public private(set) var filter: GPSFilter
    /// Events the engine created (auto-pause, auto-resume, auto-laps), for the recorder to
    /// store alongside the user's own events. User events are not repeated here.
    public private(set) var generatedEvents: [SessionEvent] = []

    private enum Mode { case moving, autoPaused, manuallyPaused }
    private struct Mark {
        var since: Double
        var movingTime: Double
        var distance: Double
        var underWayTime = 0.0
    }
    private struct LapStart {
        var since: Double
        var movingTime: Double
        var distance: Double
        var underWayTime = 0.0
        /// Distance at the last manual lap (or the start), where auto-laps count from.
        var autoLapOrigin: Double
    }

    struct MovementInterval: Sendable {
        let elapsedRange: ClosedRange<Double>
        let distance: Double

        var duration: Double { elapsedRange.upperBound - elapsedRange.lowerBound }
    }

    /// Opt-in for post-session analysis. Live sessions only need the aggregate totals.
    private(set) var movementIntervals: [MovementInterval]?
    private var pendingResumeIntervals: [MovementInterval] = []

    private var mode = Mode.moving
    private var movingTime = 0.0
    private var distance = 0.0
    private var underWayTime = 0.0
    private var lastAccepted: GPSFix?
    private var course: Double?
    /// While moving: totals when the speed first fell below the pause threshold.
    private var slow: Mark?
    /// While auto-paused: time and totals accumulated since the speed first rose.
    private var fast: Mark? {
        didSet {
            if fast == nil { pendingResumeIntervals.removeAll(keepingCapacity: true) }
        }
    }
    /// Recent accepted fixes with a speed, for the current and windowed speeds.
    private var recent: [GPSFix] = []
    private typealias SpeedBest = (mean: Double, range: ClosedRange<Double>)
    private var best2s: SpeedBest?
    private var best10s: SpeedBest?
    private var latestTime = 0.0
    private var heartRate: Double?
    private var heartRateSum = 0.0
    private var heartRateCount = 0
    private var heartRateMax: Double?
    private var laps: [Lap] = []
    private var lapStart = LapStart(since: 0, movingTime: 0, distance: 0, autoLapOrigin: 0)
    private var autoLapsSinceManual = 0
    private var acceptedFixes = 0
    private var rejectedFixes = 0
    private var finished = false
    /// Set by a manual resume: the interval from the last fix spans the pause, so the
    /// next fix starts a new interval instead of closing that one.
    private var intervalBroken = false
    private var retainedSpanStart: Double?

    public init(profile: SportProfile, filter: GPSFilter.Config = GPSFilter.Config()) {
        self.profile = profile
        self.filter = GPSFilter(config: filter)
    }

    init(profile: SportProfile, recordsMovement: Bool) {
        self.init(profile: profile)
        if recordsMovement { movementIntervals = [] }
    }

    public init(sport: Sport) {
        self.init(profile: .standard(for: sport))
    }

    /// Replay-only boundary between retained spans. Keep totals and winning speed
    /// windows, while starting the GPS and pause analysis afresh after the edit.
    mutating func skipRemovedInterval(_ interval: ClosedRange<Double>) {
        if lapStart.since < interval.lowerBound {
            closeLap(at: interval.lowerBound, isAuto: false)
        }
        lapStart = LapStart(
            since: interval.upperBound, movingTime: movingTime, distance: distance, underWayTime: underWayTime,
            autoLapOrigin: distance)
        autoLapsSinceManual = 0
        retainedSpanStart = interval.upperBound
        filter = GPSFilter(config: filter.config)
        lastAccepted = nil
        course = nil
        recent.removeAll(keepingCapacity: true)
        intervalBroken = false
        mode = .moving
        slow = nil
        fast = nil
        heartRate = nil
    }

    public mutating func ingest(_ sample: Sample) {
        guard !finished, sample.t.isFinite else { return }
        latestTime = max(latestTime, sample.t)
        switch sample {
        case .gps(let fix): ingestFix(fix)
        case .hr(let hr): ingestHeartRate(hr)
        case .event(let event): ingestEvent(event)
        case .motion, .heading: break
        }
    }

    /// Moves the session clock forward without a sample, so time-based values (elapsed
    /// time, blanking a stale current speed) stay current while the sensors are quiet.
    public mutating func advance(to t: Double) {
        guard !finished, t.isFinite else { return }
        latestTime = max(latestTime, t)
    }

    public var snapshot: LiveMetrics {
        LiveMetrics(
            elapsed: latestTime, movingTime: movingTime, distance: distance, underWayTime: underWayTime,
            speed: currentSpeed, averageSpeed: movingTime > 0 ? distance / movingTime : nil,
            maxSpeed2s: best2s?.mean, maxSpeed10s: best10s?.mean,
            maxSpeed2sRange: best2s?.range, maxSpeed10sRange: best10s?.range, course: course,
            latitude: lastAccepted?.latitude, longitude: lastAccepted?.longitude,
            heartRate: heartRate, heartRateAverage: heartRateCount > 0 ? heartRateSum / Double(heartRateCount) : nil,
            heartRateMax: heartRateMax,
            pauseState: pauseState, laps: laps, currentLap: lap(endingAt: latestTime, isAuto: false),
            acceptedFixes: acceptedFixes, rejectedFixes: rejectedFixes, isFinished: finished)
    }

    private var pauseState: LiveMetrics.PauseState {
        switch mode {
        case .moving: .moving
        case .autoPaused: .autoPaused
        case .manuallyPaused: .manuallyPaused
        }
    }

    // MARK: - GPS

    private mutating func ingestFix(_ fix: GPSFix) {
        guard case .accepted(let accepted) = filter.ingest(fix) else {
            rejectedFixes += 1
            return
        }
        acceptedFixes += 1
        course = accepted.course
        let previous = lastAccepted
        lastAccepted = fix

        var dt = 0.0
        var step = 0.0
        let startsInterval = accepted.isAnchor || intervalBroken
        intervalBroken = false
        if startsInterval {
            // Hold timers must not be satisfied by time nobody observed.
            slow = nil
            fast = nil
        }
        if let previous, !startsInterval {
            dt = fix.t - previous.t
            step = Geo.distance(
                lat1: previous.latitude, lon1: previous.longitude, lat2: fix.latitude, lon2: fix.longitude)
        }
        let speed = fix.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        // The interval's speed is the mean of its two Doppler readings (or the one known).
        let previousSpeed = startsInterval ? nil : previous?.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let intervalSpeed: Double? =
            switch (previousSpeed, speed) {
            case (let a?, let b?): (a + b) / 2
            case (let a?, nil): a
            case (nil, let b?): b
            case (nil, nil): nil
            }
        account(
            dt: dt, step: step, speed: speed, underWay: (intervalSpeed ?? 0) >= Self.underWaySpeed, at: fix.t,
            intervalStart: startsInterval ? fix.t : (previous?.t ?? fix.t))
        updateSpeeds(fix, speed: speed)
        // Auto-laps fall at whole multiples of the lap distance from the last manual lap,
        // so one lap's overshoot is not added to the next. The epsilon absorbs rounding
        // in the summed great-circle steps.
        if let lapDistance = profile.autoLapDistance, lapDistance > 0, mode == .moving,
            distance + 1e-6 >= lapStart.autoLapOrigin + lapDistance * Double(autoLapsSinceManual + 1)
        {
            autoLapsSinceManual += 1
            closeLap(at: fix.t, isAuto: true)
        }
    }

    /// Adds one interval between accepted fixes to the totals and runs auto-pause.
    private mutating func account(
        dt: Double, step: Double, speed: Double?, underWay: Bool, at t: Double, intervalStart: Double
    ) {
        let config = profile.autoPause
        switch mode {
        case .manuallyPaused:
            return
        case .moving:
            movingTime += dt
            distance += step
            if underWay { underWayTime += dt }
            if dt > 0 {
                movementIntervals?.append(MovementInterval(elapsedRange: intervalStart...t, distance: step))
            }
            guard config.enabled, let speed else { return }
            if speed < config.pauseBelow {
                let mark = slow ?? Mark(since: t, movingTime: movingTime, distance: distance, underWayTime: underWayTime)
                slow = mark
                if t - mark.since >= config.pauseAfter {
                    // Date the pause back to when the boat slowed down, but not past the
                    // start of the current lap: closed laps keep their totals.
                    let mark =
                        lapStart.since > mark.since
                        ? Mark(
                            since: lapStart.since, movingTime: lapStart.movingTime, distance: lapStart.distance,
                            underWayTime: lapStart.underWayTime)
                        : mark
                    movingTime = mark.movingTime
                    distance = mark.distance
                    underWayTime = mark.underWayTime
                    // The checkpoint keeps the intervals that had been booked by this
                    // time, including when a manual lap closed between fixes.
                    while let last = movementIntervals?.last, last.elapsedRange.upperBound > mark.since {
                        movementIntervals?.removeLast()
                    }
                    mode = .autoPaused
                    slow = nil
                    generatedEvents.append(SessionEvent(t: mark.since, type: .pause, data: ["auto": true]))
                }
            } else {
                slow = nil
            }
        case .autoPaused:
            guard let speed, speed >= config.resumeAbove else {
                fast = nil
                return
            }
            var mark = fast ?? Mark(since: intervalStart, movingTime: 0, distance: 0)
            mark.movingTime += dt
            mark.distance += step
            if underWay { mark.underWayTime += dt }
            fast = mark
            if dt > 0, movementIntervals != nil {
                pendingResumeIntervals.append(MovementInterval(elapsedRange: intervalStart...t, distance: step))
            }
            if t - mark.since >= config.resumeAfter {
                // Date the resume back to when the boat started moving again.
                movingTime += mark.movingTime
                distance += mark.distance
                underWayTime += mark.underWayTime
                movementIntervals?.append(contentsOf: pendingResumeIntervals)
                mode = .moving
                fast = nil
                generatedEvents.append(SessionEvent(t: mark.since, type: .resume, data: ["auto": true]))
            }
        }
    }

    private mutating func updateSpeeds(_ fix: GPSFix, speed: Double?) {
        guard speed != nil else { return }
        recent.append(fix)
        let keep = fix.t - 2 * Self.maxSpeedWindows.long
        if let firstKept = recent.firstIndex(where: { $0.t >= keep }), firstKept > 0 {
            recent.removeFirst(firstKept)
        }
        let profile = SpeedProfile(recent)
        for (window, keyPath) in [
            (Self.maxSpeedWindows.short, \SessionEngine.best2s), (Self.maxSpeedWindows.long, \.best10s),
        ] {
            let start = fix.t - window
            guard let area = profile.integral(from: start, to: fix.t, maxGap: window) else { continue }
            let mean = area / window
            if let best = self[keyPath: keyPath], !(best.mean < mean) { continue }
            self[keyPath: keyPath] = (mean, start...fix.t)
        }
    }

    private var currentSpeed: Double? {
        // A stale speed is worse than none: blank it when the GPS has gone quiet.
        guard let last = recent.last, latestTime - last.t <= Self.staleSpeedAfter else { return nil }
        let window = recent.filter { last.t - $0.t < Self.currentSpeedWindow }.compactMap(\.speed)
        return window.isEmpty ? nil : window.reduce(0, +) / Double(window.count)
    }

    // MARK: - Heart rate

    private mutating func ingestHeartRate(_ sample: HRSample) {
        guard sample.bpm.isFinite, sample.bpm > 0 else { return }
        heartRate = sample.bpm
        heartRateSum += sample.bpm
        heartRateCount += 1
        heartRateMax = max(heartRateMax ?? sample.bpm, sample.bpm)
    }

    // MARK: - Events

    private mutating func ingestEvent(_ event: SessionEvent) {
        switch event.type {
        case .pause:
            mode = .manuallyPaused
            slow = nil
            fast = nil
        case .resume:
            // At a cut boundary there is no pre-pause fix to disconnect in this span.
            if mode == .manuallyPaused, event.t != retainedSpanStart { intervalBroken = true }
            if mode != .moving { mode = .moving }
            slow = nil
            fast = nil
        case .lap:
            closeLap(at: event.t, isAuto: false)
        case .stop:
            finished = true
        default:
            break
        }
    }

    private mutating func closeLap(at t: Double, isAuto: Bool) {
        laps.append(lap(endingAt: t, isAuto: isAuto))
        if !isAuto { autoLapsSinceManual = 0 }
        lapStart = LapStart(
            since: t, movingTime: movingTime, distance: distance, underWayTime: underWayTime,
            autoLapOrigin: isAuto ? lapStart.autoLapOrigin : distance)
        if isAuto { generatedEvents.append(SessionEvent(t: t, type: .lap, data: ["auto": true])) }
    }

    private func lap(endingAt t: Double, isAuto: Bool) -> Lap {
        Lap(
            index: laps.count + 1, start: lapStart.since, end: max(t, lapStart.since),
            movingTime: max(0, movingTime - lapStart.movingTime), distance: max(0, distance - lapStart.distance),
            isAuto: isAuto)
    }
}
