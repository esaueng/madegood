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
    /// Mean Doppler speed over the last few seconds, m/s.
    public var speed: Double?
    /// Distance over moving time, m/s.
    public var averageSpeed: Double?
    /// Best mean Doppler speed over any 2 s and 10 s window so far, m/s.
    public var maxSpeed2s: Double?
    public var maxSpeed10s: Double?
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
    }
    private struct LapStart {
        var since: Double
        var movingTime: Double
        var distance: Double
        /// Distance at the last manual lap (or the start), where auto-laps count from.
        var autoLapOrigin: Double
    }

    private var mode = Mode.moving
    private var movingTime = 0.0
    private var distance = 0.0
    private var lastAccepted: GPSFix?
    private var course: Double?
    /// While moving: totals when the speed first fell below the pause threshold.
    private var slow: Mark?
    /// While auto-paused: time and totals accumulated since the speed first rose.
    private var fast: Mark?
    /// Recent accepted fixes with a speed, for the current and windowed speeds.
    private var recent: [GPSFix] = []
    private var maxSpeed2s: Double?
    private var maxSpeed10s: Double?
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

    public init(profile: SportProfile, filter: GPSFilter.Config = GPSFilter.Config()) {
        self.profile = profile
        self.filter = GPSFilter(config: filter)
    }

    public init(sport: Sport) {
        self.init(profile: .standard(for: sport))
    }

    public mutating func ingest(_ sample: Sample) {
        guard !finished else { return }
        latestTime = max(latestTime, sample.t)
        switch sample {
        case .gps(let fix): ingestFix(fix)
        case .hr(let hr): ingestHeartRate(hr)
        case .event(let event): ingestEvent(event)
        case .motion, .heading: break
        }
    }

    public var snapshot: LiveMetrics {
        LiveMetrics(
            elapsed: latestTime, movingTime: movingTime, distance: distance,
            speed: currentSpeed, averageSpeed: movingTime > 0 ? distance / movingTime : nil,
            maxSpeed2s: maxSpeed2s, maxSpeed10s: maxSpeed10s, course: course,
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
        if let previous, !accepted.isAnchor {
            dt = fix.t - previous.t
            step = Geo.distance(
                lat1: previous.latitude, lon1: previous.longitude, lat2: fix.latitude, lon2: fix.longitude)
        }
        let speed = fix.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        account(dt: dt, step: step, speed: speed, at: fix.t, intervalStart: previous?.t ?? fix.t)
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
    private mutating func account(dt: Double, step: Double, speed: Double?, at t: Double, intervalStart: Double) {
        let config = profile.autoPause
        switch mode {
        case .manuallyPaused:
            return
        case .moving:
            movingTime += dt
            distance += step
            guard config.enabled, let speed else { return }
            if speed < config.pauseBelow {
                let mark = slow ?? Mark(since: t, movingTime: movingTime, distance: distance)
                slow = mark
                if t - mark.since >= config.pauseAfter {
                    // Date the pause back to when the boat slowed down.
                    movingTime = mark.movingTime
                    distance = mark.distance
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
            fast = mark
            if t - mark.since >= config.resumeAfter {
                // Date the resume back to when the boat started moving again.
                movingTime += mark.movingTime
                distance += mark.distance
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
            (Self.maxSpeedWindows.short, \SessionEngine.maxSpeed2s), (Self.maxSpeedWindows.long, \.maxSpeed10s),
        ] {
            guard let area = profile.integral(from: fix.t - window, to: fix.t, maxGap: window) else { continue }
            let mean = area / window
            self[keyPath: keyPath] = max(self[keyPath: keyPath] ?? mean, mean)
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
            since: t, movingTime: movingTime, distance: distance,
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
