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
    /// Distance divided by the GPS time span, m/s.
    public var averageSpeed: Double?
    /// Best time-weighted average Doppler speed over any 2 s and 10 s window, m/s.
    public var maxSpeed2s: Double?
    public var maxSpeed10s: Double?
    public var heartRateAverage: Double?
    public var heartRateMax: Double?
    public var events: [String: Int]
    public var issues: [String]

    public static let gapFactor = 3.0
    /// Fixes with a larger horizontal accuracy radius are ignored (docs/PLAN.md §5).
    public static let maxHorizontalAccuracy = 25.0
}

extension SessionStats {
    public init(session: RawSession) {
        self.init(
            track: session.track(), motion: session.motion.map(\.t), heading: session.heading.map(\.t),
            duration: session.duration, issues: session.issues.map(\.description))
    }

    public init(
        track: Track, motion: [Double] = [], heading: [Double] = [], duration: Double? = nil,
        issues: [String] = []
    ) {
        sessionId = track.sessionId.uuidString.lowercased()
        sport = track.sport.rawValue
        startedAt = Timestamp.format(track.startedAt)
        self.duration = duration ?? track.duration
        var streams = [
            "gps": Self.streamStats(track.gps.map(\.t)),
            "hr": Self.streamStats(track.hr.map(\.t)),
            "events": Self.streamStats(track.events.map(\.t)),
        ]
        if !motion.isEmpty { streams["motion"] = Self.streamStats(motion) }
        if !heading.isEmpty { streams["heading"] = Self.streamStats(heading) }
        self.streams = streams

        let accepted = track.gps.filter { ($0.horizontalAccuracy ?? 0) <= Self.maxHorizontalAccuracy }
        acceptedFixes = accepted.count
        rejectedFixes = track.gps.count - accepted.count
        distance = zip(accepted, accepted.dropFirst()).reduce(0) { sum, pair in
            sum
                + Geo.distance(
                    lat1: pair.0.latitude, lon1: pair.0.longitude,
                    lat2: pair.1.latitude, lon2: pair.1.longitude)
        }
        if let first = accepted.first, let last = accepted.last, last.t > first.t {
            averageSpeed = distance / (last.t - first.t)
        } else {
            averageSpeed = nil
        }
        maxSpeed2s = Self.bestAverageSpeed(accepted, window: 2)
        maxSpeed10s = Self.bestAverageSpeed(accepted, window: 10)

        let bpm = track.hr.map(\.bpm)
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

    /// Best time-weighted mean speed over a window of at least `window` seconds, using
    /// trapezoidal integration between consecutive fixes with a speed. Windows spanning a
    /// gap longer than the window itself are skipped.
    static func bestAverageSpeed(_ fixes: [GPSFix], window: Double) -> Double? {
        let points = fixes.compactMap { fix in fix.speed.map { (t: fix.t, v: $0) } }
        guard points.count >= 2 else { return nil }
        var best: Double?
        // Each window holds only a few fixes at 1 Hz, so a direct scan is cheap and clear.
        for start in points.indices {
            var area = 0.0
            var end = start
            while end + 1 < points.count, points[end].t - points[start].t < window {
                let a = points[end]
                let b = points[end + 1]
                if b.t - a.t > window { break }
                area += (a.v + b.v) / 2 * (b.t - a.t)
                end += 1
            }
            let span = points[end].t - points[start].t
            guard span >= window else { continue }
            let mean = area / span
            best = max(best ?? mean, mean)
        }
        return best
    }
}
