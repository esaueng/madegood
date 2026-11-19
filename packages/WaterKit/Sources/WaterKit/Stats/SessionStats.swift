import Foundation

/// Basic, sport-independent statistics for inspecting a recording: what was captured,
/// at what rate, with what gaps, and the headline distance and speed figures.
///
/// These are diagnostics for Phase 0 recordings, not the final metric definitions;
/// those live in docs/metrics.md as each one is built.
public struct SessionStats: Sendable, Hashable, Codable {
    public struct StreamStats: Sendable, Hashable, Codable {
        public var count: Int
        /// First and last sample time, s since start.
        public var start: Double?
        public var end: Double?
        /// Median sampling rate, Hz (1 / median interval).
        public var medianRate: Double?
        /// Intervals longer than `gapFactor` × the median interval.
        public var gaps: Int
        public var longestGap: Double?
    }

    public var sessionId: String
    public var sport: String
    public var startedAt: String
    /// s
    public var duration: Double
    public var streams: [String: StreamStats]
    /// Sum of great-circle steps between accepted fixes, m.
    public var distance: Double
    /// Fixes used for distance and speed (horizontal accuracy within the limit).
    public var acceptedFixes: Int
    public var rejectedFixes: Int
    /// Time-weighted mean Doppler speed over the fixes the live GPS filter accepts,
    /// excluding gaps, m/s.
    public var averageSpeed: Double?
    /// The live engine's max speeds: best time-weighted mean Doppler speed over 2 s and
    /// 10 s windows ending at a fix, over GPS-filtered fixes, m/s.
    public var maxSpeed2s: Double?
    public var maxSpeed10s: Double?
    /// Windsurfing only: speedsurfing categories over the live engine's accepted fixes, m/s,
    /// keyed like the track summary (docs/metrics.md). Missing categories are left out.
    public var speedCategories: [String: Double]?
    public var heartRateAverage: Double?
    public var heartRateMax: Double?
    public var events: [String: Int]
    public var issues: [String]
    /// Paddle strokes, for kayak, canoe and SUP recordings with motion (docs/metrics.md "Strokes").
    public var strokes: StrokeStats?
    /// Sailing recordings: the track's wind estimate, maneuvers and VMG (docs/metrics.md
    /// "Sailing wind and VMG"). No prior, so the wind assumes the legs are upwind.
    public var sailing: SailingStats?

    public struct SailingStats: Sendable, Hashable, Codable {
        /// Degrees true; nil without an estimate.
        public var windFrom: Double?
        public var windConfidence: Double?
        public var tacks: Int
        public var gybes: Int
        /// m/s
        public var upwindVMG: Double?
        public var downwindVMG: Double?
    }

    public struct StrokeStats: Sendable, Hashable, Codable {
        public var count: Int
        /// SPM
        public var averageRate: Double?
        /// m, over the distance above
        public var distancePerStroke: Double?
        public var sideSwitches: Int?
        /// Share of strokes on the side paddled first, 0–1.
        public var sideBalance: Double?
    }

    public static let gapFactor = 3.0
    /// Fixes with a larger horizontal accuracy radius are ignored (docs/PLAN.md §5).
    public static let maxHorizontalAccuracy = 25.0
    /// Intervals between fixes longer than this are left out of the average speed, s.
    public static let maxSpeedGap = 10.0
}

extension SessionStats {
    public init(session: RawSession) {
        self.init(
            track: session.track(), motion: session.motion.map(\.t), heading: session.heading.map(\.t),
            duration: session.duration, issues: session.issues.map(\.description))
        if session.meta.sport.isPaddling, !session.motion.isEmpty {
            let analysis = StrokeAnalysis(
                detection: StrokeAnalysis.detect(session: session), sport: session.meta.sport, distance: distance)
            let singleBlade = session.meta.sport != .kayak
            strokes = StrokeStats(
                count: analysis.strokeCount, averageRate: analysis.averageStrokeRate,
                distancePerStroke: analysis.distancePerStroke, sideSwitches: singleBlade ? analysis.sideSwitches : nil,
                sideBalance: analysis.sideBalance)
        }
        if session.meta.sport == .sailing, let selection = try? SessionSelection(session: session) {
            let analysis = selection.sailingAnalysis()
            sailing = SailingStats(
                windFrom: analysis.windFrom, windConfidence: analysis.estimate?.confidence, tacks: analysis.tackCount,
                gybes: analysis.gybeCount, upwindVMG: analysis.upwindVMG, downwindVMG: analysis.downwindVMG)
        }
    }

    public init(
        track: Track, motion: [Double] = [], heading: [Double] = [], duration: Double? = nil,
        issues: [String] = []
    ) {
        sessionId = track.sessionId.uuidString.lowercased()
        sport = track.sport.rawValue
        startedAt = Timestamp.format(track.startedAt)
        self.duration = duration ?? track.duration
        // Track files keep their column order, so put everything in time order first.
        let gps = Self.timeOrdered(track.gps, \.t)
        let hr = Self.timeOrdered(track.hr, \.t)
        var streams = [
            "gps": Self.streamStats(gps.map(\.t)),
            "hr": Self.streamStats(hr.map(\.t)),
            "events": Self.streamStats(track.events.map(\.t).sorted()),
        ]
        if !motion.isEmpty { streams["motion"] = Self.streamStats(motion.sorted()) }
        if !heading.isEmpty { streams["heading"] = Self.streamStats(heading.sorted()) }
        self.streams = streams

        // A fix without an accuracy value is unknown quality, not perfect quality.
        let accepted = gps.filter { fix in
            fix.horizontalAccuracy.map { $0.isFinite && $0 <= Self.maxHorizontalAccuracy } ?? false
        }
        acceptedFixes = accepted.count
        rejectedFixes = gps.count - accepted.count
        distance = zip(accepted, accepted.dropFirst()).reduce(0) { sum, pair in
            sum
                + Geo.distance(
                    lat1: pair.0.latitude, lon1: pair.0.longitude,
                    lat2: pair.1.latitude, lon2: pair.1.longitude)
        }
        // Speeds come from the receiver's Doppler values, never from position changes
        // (docs/PLAN.md §4.2), over the fixes the live engine's GPS filter accepts, so
        // every speed shown here matches live and session detail.
        let replay = SessionReplay(track: track)
        averageSpeed = SpeedProfile(replay.fixes).mean(maxGap: Self.maxSpeedGap)
        maxSpeed2s = replay.metrics.maxSpeed2s
        maxSpeed10s = replay.metrics.maxSpeed10s
        speedCategories = track.sport == .windsurfing ? replay.metrics.speedCategories?.summaryFields : nil

        let bpm = hr.map(\.bpm)
        heartRateAverage = bpm.isEmpty ? nil : bpm.reduce(0, +) / Double(bpm.count)
        heartRateMax = bpm.max()
        events = track.events.reduce(into: [:]) { $0[$1.type.rawValue, default: 0] += 1 }
        self.issues = issues
    }

    static func streamStats(_ times: [Double]) -> StreamStats {
        guard let first = times.first, let last = times.last else {
            return StreamStats(count: 0, gaps: 0)
        }
        let intervals = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard !intervals.isEmpty else {
            return StreamStats(count: times.count, start: first, end: last, gaps: 0)
        }
        let sorted = intervals.sorted()
        let median =
            sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let gapIntervals = intervals.filter { $0 > median * gapFactor }
        return StreamStats(
            count: times.count, start: first, end: last, medianRate: 1 / median,
            gaps: gapIntervals.count, longestGap: gapIntervals.max())
    }

    /// Time-weighted mean of the speed profile over `window` seconds (diagnostic).
    static func bestAverageSpeed(_ fixes: [GPSFix], window: Double) -> Double? {
        SpeedProfile(fixes).bestMean(window: window)
    }

    static func timeOrdered<T>(_ items: [T], _ time: (T) -> Double) -> [T] {
        items.enumerated()
            .sorted {
                time($0.element) != time($1.element) ? time($0.element) < time($1.element) : $0.offset < $1.offset
            }
            .map(\.element)
    }
}

/// Doppler speed as a piecewise-linear function of time between consecutive fixes.
///
/// Windowed bests use windows of exactly the requested length that start or end at a
/// fix, with the other edge interpolated. That is exact for evenly spaced fixes (1 Hz
/// GPS); for uneven spacing a window starting between fixes can do slightly better. The
/// final metric definitions are documented in docs/metrics.md as they are built.
struct SpeedProfile: Sendable {
    let t: [Double]
    let v: [Double]

    init(_ fixes: [GPSFix]) {
        let points = fixes.compactMap { fix in fix.speed.flatMap { $0.isFinite ? (fix.t, $0) : nil } }
        t = points.map(\.0)
        v = points.map(\.1)
    }

    /// Mean speed over all intervals no longer than `maxGap`, s.
    func mean(maxGap: Double) -> Double? {
        var area = 0.0
        var time = 0.0
        for i in t.indices.dropLast() {
            let dt = t[i + 1] - t[i]
            guard dt > 0, dt <= maxGap else { continue }
            area += (v[i] + v[i + 1]) / 2 * dt
            time += dt
        }
        return time > 0 ? area / time : nil
    }

    /// Best mean speed over any `window`-second span with no interval longer than the window.
    func bestMean(window: Double) -> Double? {
        guard t.count >= 2, window > 0 else { return nil }
        var best: Double?
        for anchor in t {
            for (start, end) in [(anchor, anchor + window), (anchor - window, anchor)] {
                guard let area = integral(from: start, to: end, maxGap: window) else { continue }
                let mean = area / window
                best = max(best ?? mean, mean)
            }
        }
        return best
    }

    /// Integral of speed over [a, b], or nil if the span leaves the data or crosses a gap.
    func integral(from a: Double, to b: Double, maxGap: Double) -> Double? {
        guard let first = t.first, let last = t.last, a >= first, b <= last, b > a else { return nil }
        var i = segment(containing: a)
        var area = 0.0
        var position = a
        while position < b {
            let dt = t[i + 1] - t[i]
            if dt > maxGap { return nil }
            let segmentEnd = min(b, t[i + 1])
            area += (value(at: position, segment: i) + value(at: segmentEnd, segment: i)) / 2 * (segmentEnd - position)
            position = segmentEnd
            i += 1
            if i >= t.count - 1 && position < b { return nil }
        }
        return area
    }

    func interpolatedValue(at time: Double, maxGap: Double) -> Double? {
        guard let first = t.first, let last = t.last, time >= first, time <= last else { return nil }
        if time == last { return v.last }
        let i = segment(containing: time)
        if time == t[i] { return v[i] }
        guard t[i + 1] - t[i] <= maxGap else { return nil }
        return value(at: time, segment: i)
    }

    /// Index i of the segment [t[i], t[i+1]] that contains `time` (t.first <= time < t.last).
    private func segment(containing time: Double) -> Int {
        var low = 0
        var high = t.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if t[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func value(at time: Double, segment i: Int) -> Double {
        let dt = t[i + 1] - t[i]
        guard dt > 0 else { return v[i + 1] }
        return v[i] + (v[i + 1] - v[i]) * (time - t[i]) / dt
    }
}
