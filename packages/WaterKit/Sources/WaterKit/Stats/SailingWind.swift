import Foundation

/// A true-wind direction estimated from the boat's own track (docs/PLAN.md §5, "Wind
/// direction"; docs/metrics.md, "Sailing wind and VMG").
public struct WindEstimate: Sendable, Hashable {
    /// Which of the two opposite directions the legs allow is the wind's.
    public enum Side: Sendable, Hashable {
        /// No prior: the legs are assumed to be upwind, so `fromDegrees` can be 180° off
        /// (on a session spent gybing downwind). Only the axis is known.
        case unresolved
        /// A prior within `WindEstimate.priorAgreement` of one direction chose it.
        case resolvedByPrior
        /// A prior was given but lay too far from both directions to choose (the
        /// forecast's direction, degrees true). Treated like `unresolved`.
        case priorInconclusive(Double)
    }

    /// A prior chooses a direction only when it is within this many degrees of it, so
    /// it is at least 120° from the other one.
    public static let priorAgreement = 60.0

    /// Direction the wind blows from, degrees true in [0, 360). Only its axis is known
    /// unless `side` is `.resolvedByPrior`.
    public var fromDegrees: Double
    /// 0...1: how much of the sailing time sits on the two legs, scaled down while
    /// either leg is still short. It rates the axis, not which side the wind is on. A
    /// heuristic for "show it or not", not a probability.
    public var axisConfidence: Double
    /// Mean circular standard deviation of the courses on the two legs, degrees (at least
    /// half a bin): how widely the legs, and so the axis, scatter.
    public var axisUncertainty: Double
    /// The courses of the two legs either side of the wind, degrees true.
    public var legCourses: [Double]
    /// The angle between the two legs, degrees (the tacking or gybing angle).
    public var legAngle: Double
    public var side: Side

    /// True when a prior chose the side; otherwise only the axis is known, and tacks,
    /// gybes, upwind and downwind must not be told apart.
    public var resolvedByPrior: Bool { side == .resolvedByPrior }

    public init(
        fromDegrees: Double, axisConfidence: Double, axisUncertainty: Double, legCourses: [Double],
        legAngle: Double, side: Side
    ) {
        self.fromDegrees = fromDegrees
        self.axisConfidence = axisConfidence
        self.axisUncertainty = axisUncertainty
        self.legCourses = legCourses
        self.legAngle = legAngle
        self.side = side
    }
}

/// A time-weighted histogram of course over ground while sailing, the input to the wind
/// estimate. It is small and fixed in size, so the watch can keep one for a whole session.
public struct CourseHistogram: Sendable, Hashable {
    /// Bin width, degrees.
    public static let binWidth = 5.0
    static let binCount = 72
    /// Course is only sailing evidence at or above this Doppler speed, m/s (about 1.9 kn).
    public static let minimumSailingSpeed = 1.0
    /// The time one fix stands for is capped, so a gap cannot weight a single course, s.
    public static let maximumFixWeight = 5.0
    /// Legs are 70–110° apart (PLAN §5).
    public static let legAngleRange = 70.0...110.0
    /// A leg's mass is the time within ±12.5° of its bin (five bins).
    static let legHalfWidth = 2
    /// The leg direction is the circular mean of courses within ±17.5° of its bin.
    static let refineHalfWidth = 3
    /// Each leg needs this much time, and the two together `minimumPairTime`, s.
    public static let minimumLegTime = 20.0
    public static let minimumPairTime = 60.0
    /// Below this much time on the shorter leg the confidence is scaled down, s.
    static let fullConfidenceLegTime = 120.0

    private var weights = [Double](repeating: 0, count: binCount)
    private var sines = [Double](repeating: 0, count: binCount)
    private var cosines = [Double](repeating: 0, count: binCount)
    /// Total time added, s.
    public private(set) var totalTime = 0.0

    public init() {}

    /// Adds `seconds` of sailing on `course` (degrees true). Non-finite or non-positive
    /// weights are ignored.
    public mutating func add(course: Double, seconds: Double) {
        guard course.isFinite, seconds.isFinite, seconds > 0 else { return }
        let normalized = GPSFilter.normalize(course)
        let bin = Int(normalized / Self.binWidth) % Self.binCount
        let radians = normalized * .pi / 180
        weights[bin] += seconds
        sines[bin] += seconds * sin(radians)
        cosines[bin] += seconds * cos(radians)
        totalTime += seconds
    }

    /// The wind estimate: the two most-sailed courses 70–110° apart, and the direction
    /// midway between them. A prior (degrees true, from a forecast) picks which of the
    /// two opposite directions it is when it lies within `WindEstimate.priorAgreement` of
    /// one; otherwise the legs are assumed upwind and the side is left unresolved.
    /// Nil until both legs have enough time.
    public func windEstimate(prior: Double? = nil) -> WindEstimate? {
        windEstimate(prior: prior, legAngles: Self.legAngleRange)
    }

    func windEstimate(prior: Double? = nil, legAngles: ClosedRange<Double>) -> WindEstimate? {
        let n = Self.binCount
        func mass(around bin: Int, halfWidth: Int) -> Double {
            (-halfWidth...halfWidth).reduce(0) { $0 + weights[((bin + $1) % n + n) % n] }
        }
        let masses = (0..<n).map { mass(around: $0, halfWidth: Self.legHalfWidth) }
        let minimumSeparation = Int((legAngles.lowerBound / Self.binWidth).rounded())
        let maximumSeparation = Int((legAngles.upperBound / Self.binWidth).rounded())
        var best: (a: Int, b: Int, score: Double)?
        for a in 0..<n {
            for separation in minimumSeparation...maximumSeparation {
                let b = (a + separation) % n
                let (ma, mb) = (masses[a], masses[b])
                guard min(ma, mb) >= Self.minimumLegTime, ma + mb >= Self.minimumPairTime else { continue }
                if ma + mb > (best?.score ?? 0) { best = (a, b, ma + mb) }
            }
        }
        guard let best, let first = refined(best.a), let second = refined(best.b) else { return nil }
        let separation = GPSFilter.signedDifference(from: first, to: second)
        // Refinement may move the legs a little; still require two distinct legs.
        guard abs(separation) >= legAngles.lowerBound - Self.binWidth,
            abs(separation) <= legAngles.upperBound + Self.binWidth
        else { return nil }
        let bisector = GPSFilter.normalize(first + separation / 2)
        let opposite = GPSFilter.normalize(bisector + 180)

        let share = totalTime > 0 ? min(1, best.score / totalTime) : 0
        let shorterLeg = min(masses[best.a], masses[best.b])
        let confidence = share * min(1, shorterLeg / Self.fullConfidenceLegTime)
        var direction = bisector
        var side = WindEstimate.Side.unresolved
        if let prior, prior.isFinite {
            let toBisector = abs(GPSFilter.signedDifference(from: prior, to: bisector))
            let toOpposite = abs(GPSFilter.signedDifference(from: prior, to: opposite))
            if toBisector <= WindEstimate.priorAgreement {
                side = .resolvedByPrior
            } else if toOpposite <= WindEstimate.priorAgreement {
                direction = opposite
                side = .resolvedByPrior
            } else {
                side = .priorInconclusive(GPSFilter.normalize(prior))
            }
        }
        let spread = (spread(best.a) + spread(best.b)) / 2
        return WindEstimate(
            fromDegrees: direction, axisConfidence: confidence, axisUncertainty: max(Self.binWidth / 2, spread),
            legCourses: [first, second].sorted(), legAngle: abs(separation), side: side)
    }

    /// Time-weighted circular standard deviation of courses around a bin, degrees.
    private func spread(_ bin: Int) -> Double {
        let n = Self.binCount
        var (s, c, w) = (0.0, 0.0, 0.0)
        for offset in -Self.refineHalfWidth...Self.refineHalfWidth {
            let index = ((bin + offset) % n + n) % n
            s += sines[index]
            c += cosines[index]
            w += weights[index]
        }
        guard w > 0 else { return 0 }
        let resultant = min(1, (s * s + c * c).squareRoot() / w)
        return (-2 * log(max(resultant, 1e-12))).squareRoot() * 180 / .pi
    }

    /// Sailing time within ±12.5° of each of an estimate's legs, s: how strongly the
    /// track supports that axis.
    func legTime(_ estimate: WindEstimate) -> Double {
        let n = Self.binCount
        return estimate.legCourses.reduce(0) { total, course in
            let bin = Int(GPSFilter.normalize(course) / Self.binWidth) % n
            return total
                + (-Self.legHalfWidth...Self.legHalfWidth).reduce(0) { $0 + weights[((bin + $1) % n + n) % n] }
        }
    }

    /// Time-weighted circular mean course around a bin, degrees true.
    private func refined(_ bin: Int) -> Double? {
        let n = Self.binCount
        var (s, c) = (0.0, 0.0)
        for offset in -Self.refineHalfWidth...Self.refineHalfWidth {
            let index = ((bin + offset) % n + n) % n
            s += sines[index]
            c += cosines[index]
        }
        guard s != 0 || c != 0 else { return nil }
        return GPSFilter.normalize(atan2(s, c) * 180 / .pi)
    }
}

/// Velocity made good against the wind.
public enum SailingVMG {
    /// True wind angle: the wind's direction relative to the bow, degrees in (-180, 180].
    /// Positive when the wind comes over the starboard side (starboard tack).
    public static func trueWindAngle(course: Double, windFrom: Double) -> Double {
        GPSFilter.signedDifference(from: course, to: windFrom)
    }

    /// Speed toward the wind, m/s: `speed × cos(true wind angle)`. Negative downwind.
    public static func vmg(speed: Double, course: Double, windFrom: Double) -> Double {
        speed * cos(trueWindAngle(course: course, windFrom: windFrom) * .pi / 180)
    }

    /// Upwind is a true wind angle below this, degrees; downwind is above 180 minus it.
    /// Reaching in between counts toward neither VMG.
    public static let upwindLimit = 80.0
}

/// Time and Doppler distance on one tack.
public struct SailingTackTotals: Sendable, Hashable {
    public var time = 0.0
    public var distance = 0.0

    public init(time: Double = 0, distance: Double = 0) {
        self.time = time
        self.distance = distance
    }
}

/// Post-session sailing analysis: wind, maneuvers and VMG (docs/metrics.md).
public struct SailingAnalysis: Sendable {
    public enum WindSource: Sendable, Hashable {
        /// The user entered the direction.
        case user
        /// Estimated from the track.
        case estimate
        /// No direction: too little evidence and none entered.
        case none
    }

    /// The wind-from direction the analysis used, degrees true.
    public var windFrom: Double?
    public var windSource: WindSource
    /// The track's own estimate, also when the user's direction was used.
    public var estimate: WindEstimate?
    public var maneuvers: [SailingManeuver]
    /// Mean VMG while sailing upwind / downwind, m/s (downwind as a positive speed away
    /// from the wind). Nil without wind or time in that mode.
    public var upwindVMG: Double?
    public var downwindVMG: Double?
    /// Mean true wind angle while sailing upwind, degrees.
    public var pointingAngle: Double?
    /// Time and distance with the wind over the starboard / port side, outside maneuvers.
    public var starboard: SailingTackTotals
    public var port: SailingTackTotals
    /// Side-independent figures, for when only the wind's axis is known: mean |VMG| and
    /// mean angle to the axis (0–90°) while not reaching. Nil without such time.
    public var axisVMG: Double?
    public var axisAngle: Double?

    /// Whether the wind's side is known: the user entered it, or a forecast chose it.
    /// When false, upwind/downwind, tack/gybe and starboard/port must not be shown.
    public var windResolved: Bool {
        windSource == .user || (windSource == .estimate && estimate?.resolvedByPrior == true)
    }

    public var tackCount: Int { maneuvers.count { $0.event.type == .tack } }
    public var gybeCount: Int { maneuvers.count { $0.event.type == .gybe } }
}

extension SessionSelection {
    /// Wind, maneuvers and VMG for a sailing selection. A user direction (degrees true,
    /// 0...360) is used as given; otherwise the track's estimate, with `windPrior` (for
    /// example a modelled weather direction) choosing between its two opposite directions.
    public func sailingAnalysis(windFromDegreesTrue userWind: Double? = nil, windPrior: Double? = nil)
        -> SailingAnalysis
    {
        let runs = track.sport == .sailing ? sailingObservationRuns() : []
        let estimate = Self.courseHistogram(runs).windEstimate(prior: windPrior)
        let validUser = userWind.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil }
        let wind = validUser ?? estimate?.fromDegrees
        let source: SailingAnalysis.WindSource = validUser != nil ? .user : (estimate != nil ? .estimate : .none)
        var analysis = SailingAnalysis(
            windFrom: wind, windSource: source, estimate: estimate, maneuvers: [], upwindVMG: nil, downwindVMG: nil,
            pointingAngle: nil, starboard: SailingTackTotals(), port: SailingTackTotals(), axisVMG: nil,
            axisAngle: nil)
        guard track.sport == .sailing, let wind else { return analysis }
        analysis.maneuvers = SailingManeuverDetector.detect(in: runs, windFrom: wind)

        var upwind = (time: 0.0, vmg: 0.0, angle: 0.0)
        var downwind = (time: 0.0, vmg: 0.0)
        var axis = (vmg: 0.0, angle: 0.0)
        var maneuverRanges = analysis.maneuvers.map(\.range).makeIterator()
        var maneuverRange = maneuverRanges.next()
        for run in runs {
            for (a, b) in zip(run, run.dropFirst()) {
                while let range = maneuverRange, range.upperBound <= a.t { maneuverRange = maneuverRanges.next() }
                // An interval that touches a turn belongs to the turn.
                if let range = maneuverRange, b.t > range.lowerBound { continue }
                let dt = min(b.t - a.t, CourseHistogram.maximumFixWeight)
                let speed = (a.speed + b.speed) / 2
                guard dt > 0, speed >= CourseHistogram.minimumSailingSpeed else { continue }
                let angle = SailingVMG.trueWindAngle(course: a.course, windFrom: wind)
                let vmg = speed * cos(angle * .pi / 180)
                if angle > 0 {
                    analysis.starboard.time += dt
                    analysis.starboard.distance += speed * dt
                } else {
                    analysis.port.time += dt
                    analysis.port.distance += speed * dt
                }
                if abs(angle) < SailingVMG.upwindLimit || abs(angle) > 180 - SailingVMG.upwindLimit {
                    axis.vmg += abs(vmg) * dt
                    axis.angle += min(abs(angle), 180 - abs(angle)) * dt
                }
                if abs(angle) < SailingVMG.upwindLimit {
                    upwind.time += dt
                    upwind.vmg += vmg * dt
                    upwind.angle += abs(angle) * dt
                } else if abs(angle) > 180 - SailingVMG.upwindLimit {
                    downwind.time += dt
                    downwind.vmg -= vmg * dt
                }
            }
        }
        if upwind.time > 0 {
            analysis.upwindVMG = upwind.vmg / upwind.time
            analysis.pointingAngle = upwind.angle / upwind.time
        }
        if downwind.time > 0 { analysis.downwindVMG = downwind.vmg / downwind.time }
        if upwind.time + downwind.time > 0 {
            analysis.axisVMG = axis.vmg / (upwind.time + downwind.time)
            analysis.axisAngle = axis.angle / (upwind.time + downwind.time)
        }
        return analysis
    }

    /// The track's wind estimate on its own (see `sailingAnalysis`).
    public func estimatedWind(prior: Double? = nil) -> WindEstimate? {
        guard track.sport == .sailing else { return nil }
        return Self.courseHistogram(sailingObservationRuns()).windEstimate(prior: prior)
    }

    static func courseHistogram(
        _ runs: [[SailingObservation]], minimumSpeed: Double = CourseHistogram.minimumSailingSpeed
    ) -> CourseHistogram {
        var histogram = CourseHistogram()
        for run in runs {
            for (a, b) in zip(run, run.dropFirst()) where a.speed >= minimumSpeed {
                histogram.add(course: a.course, seconds: min(b.t - a.t, CourseHistogram.maximumFixWeight))
            }
        }
        return histogram
    }
}

/// Live sailing state for the sport page.
public struct LiveSailing: Sendable, Hashable {
    /// The track's wind estimate so far; nil until both legs have enough time.
    public var wind: WindEstimate?
    /// Tacks and gybes so far, against the current estimate. Live the estimate has no
    /// prior, so a tack and a gybe can swap: show `maneuverCount` unless the wind's side
    /// is resolved.
    public var tacks: Int
    public var gybes: Int
    /// Current VMG and true wind angle from the current speed and smoothed course; nil
    /// without a wind estimate, speed or course.
    public var vmg: Double?
    public var trueWindAngle: Double?

    public var maneuverCount: Int { tacks + gybes }

    public init(
        wind: WindEstimate? = nil, tacks: Int = 0, gybes: Int = 0, vmg: Double? = nil, trueWindAngle: Double? = nil
    ) {
        self.wind = wind
        self.tacks = tacks
        self.gybes = gybes
        self.vmg = vmg
        self.trueWindAngle = trueWindAngle
    }
}

/// The causal side of the sailing analysis, fed by the session engine with accepted fixes.
/// It applies the post-session rules to what it has seen so far, so the counts converge on
/// session detail's. Every `refreshInterval` it re-estimates the wind and scans only the
/// recent observations (a window reaching `rescanMargin` before the last scan), keeping
/// the maneuvers already found. All observations are rescanned only when the estimate
/// has moved more than `rescanWindChange` since the maneuvers were found, and at the end.
struct SailingTracker: Sendable {
    static let refreshInterval = 10.0
    /// Longer than a turn (20 s) plus both legs (5 s each) and the median's reach, s.
    static let rescanMargin = 60.0
    /// The axis may drift this far before the stored maneuvers are rescanned, degrees.
    static let rescanWindChange = 10.0
    /// A different axis replaces the shown one only after winning this many refreshes in
    /// a row by `axisSwitchMargin` of leg time, so two near-equal axes cannot alternate.
    static let axisSwitchRefreshes = 6
    static let axisSwitchMargin = 1.1
    /// Full rescans run at most this often while live (the stop always runs one), s.
    static let minimumRescanInterval = 300.0

    /// Every observation and the run it belongs to (a change of run ID starts a new
    /// run), in a reference buffer that is copied only when shared, and counted then.
    private final class Store: @unchecked Sendable {
        // Mutated only through `SailingTracker.append`, after a uniqueness check.
        var observations: [SailingObservation] = []
        var runIDs: [Int] = []

        func copy() -> Store {
            let store = Store()
            store.observations = observations
            store.runIDs = runIDs
            return store
        }
    }

    private var store = Store()
    private var observations: [SailingObservation] { store.observations }
    private var runIDs: [Int] { store.runIDs }
    /// For tests: how often the history was copied because the tracker (inside its engine)
    /// was mutated while another copy still shared it. In place it stays 0.
    private(set) var storageCopies = 0
    private var runID = 0
    private var runOpen = false
    /// The last accepted fix, usable or not: a longer gap than the replay route's breaks
    /// the run, as after the session.
    private var lastFixTime: Double?
    private var histogram = CourseHistogram()
    private var lastRefresh = -Double.infinity
    private var lastScan = -Double.infinity
    private var lastFullRescan = -Double.infinity
    /// The wind the stored maneuvers were found against, degrees true.
    private var scanWind: Double?
    /// A different axis waiting to replace the shown one, and for how many refreshes it has won.
    private var pendingAxis: (estimate: WindEstimate, refreshes: Int)?
    private var maneuvers: [SailingManeuver] = []
    /// The estimate shown (with hysteresis; see `axisSwitchRefreshes`).
    private(set) var wind: WindEstimate?
    /// For tests: how many times every observation was rescanned.
    private(set) var fullRescans = 0

    /// Turns found so far. Live they are never removed, so the counts only grow.
    var tacks: Int { maneuvers.count { $0.event.type == .tack } }
    var gybes: Int { maneuvers.count - tacks }

    /// One accepted fix. `course` is the receiver's raw course, as post-session.
    mutating func ingest(t: Double, speed: Double?, course: Double?, courseAccuracy: Double?) {
        if let lastFixTime, t - lastFixTime > SessionReplayTimeline.maxRouteGap { breakRun() }
        lastFixTime = t
        guard let speed, speed >= SailingManeuverDetector.minimumCourseSpeed,
            let course, (0...360).contains(course),
            SailingManeuverDetector.reliableCourseAccuracy(courseAccuracy)
        else {
            breakRun()
            return
        }
        if runOpen, let last = observations.last {
            guard t > last.t else { return }
            if last.speed >= CourseHistogram.minimumSailingSpeed {
                histogram.add(course: last.course, seconds: min(t - last.t, CourseHistogram.maximumFixWeight))
            }
        }
        if !runOpen {
            runID += 1
            runOpen = true
        }
        if !isKnownUniquelyReferenced(&store) {
            store = store.copy()
            storageCopies += 1
        }
        store.observations.append(SailingObservation(t: t, speed: speed, course: course))
        store.runIDs.append(runID)
        if t - lastRefresh >= Self.refreshInterval { refresh(at: t, final: false) }
    }

    /// A pause, GPS anchor or unreliable course: evidence on either side is not joined.
    mutating func breakRun() {
        runOpen = false
    }

    /// The session ended: a last full rescan, so a turn completed since the last periodic
    /// refresh is counted.
    mutating func finish(at t: Double) {
        breakRun()
        refresh(at: t, final: true)
    }

    private static func axisDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(GPSFilter.signedDifference(from: a, to: b))
        return min(d, 180 - d)
    }

    private mutating func updateWind() {
        guard let candidate = histogram.windEstimate() else { return }
        guard let current = wind else {
            wind = candidate
            return
        }
        if Self.axisDifference(current.fromDegrees, candidate.fromDegrees) <= Self.rescanWindChange {
            // The same axis, drifting: follow it.
            wind = candidate
            pendingAxis = nil
            return
        }
        guard histogram.legTime(candidate) >= Self.axisSwitchMargin * histogram.legTime(current) else {
            pendingAxis = nil
            return
        }
        let refreshes =
            pendingAxis.map {
                Self.axisDifference($0.estimate.fromDegrees, candidate.fromDegrees) <= Self.rescanWindChange
                    ? $0.refreshes + 1 : 1
            } ?? 1
        if refreshes >= Self.axisSwitchRefreshes {
            wind = candidate
            pendingAxis = nil
        } else {
            pendingAxis = (candidate, refreshes)
        }
    }

    private mutating func refresh(at t: Double, final: Bool) {
        lastRefresh = t
        updateWind()
        guard let direction = wind?.fromDegrees else { return }
        let moved = scanWind.map { abs(GPSFilter.signedDifference(from: $0, to: direction)) } ?? .infinity
        let rescanDue = moved > Self.rescanWindChange && t - lastFullRescan >= Self.minimumRescanInterval
        if final || scanWind == nil || rescanDue {
            // Keep every turn already counted; add the ones this axis finds elsewhere.
            merge(SailingManeuverDetector.detect(in: runs(from: 0), windFrom: direction))
            scanWind = direction
            lastFullRescan = t
            fullRescans += 1
        } else if let scanWind {
            let first = firstIndex(atOrAfter: lastScan - Self.rescanMargin)
            merge(SailingManeuverDetector.detect(in: runs(from: first), windFrom: scanWind))
        }
        lastScan = t
    }

    private mutating func merge(_ found: [SailingManeuver]) {
        var added = false
        for maneuver in found
        where !maneuvers.contains(where: { $0.range.overlaps(maneuver.range) }) {
            maneuvers.append(maneuver)
            added = true
        }
        if added { maneuvers.sort { $0.event.t < $1.event.t } }
    }

    /// Observations from `start` on, split into runs.
    private func runs(from start: Int) -> [[SailingObservation]] {
        var result: [[SailingObservation]] = []
        var index = start
        while index < observations.count {
            let id = runIDs[index]
            var end = index
            while end < observations.count, runIDs[end] == id { end += 1 }
            result.append(Array(observations[index..<end]))
            index = end
        }
        return result
    }

    private func firstIndex(atOrAfter t: Double) -> Int {
        var (low, high) = (0, observations.count)
        while low < high {
            let mid = (low + high) / 2
            if observations[mid].t < t { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
