/// A windowed best speed and the time span it covers, in seconds since session start.
public struct SpeedBest: Sendable, Hashable {
    /// Mean Doppler speed over the span, m/s.
    public var speed: Double
    /// The span's bounds. The start may fall between fixes; the end is a fix.
    public var range: ClosedRange<Double>

    public init(speed: Double, range: ClosedRange<Double>) {
        self.speed = speed
        self.range = range
    }
}

/// Speedsurfing categories (docs/PLAN.md §5, "Windsurfing / wing"; docs/metrics.md
/// "Windsurf speed categories"). Every value comes from Doppler speed, m/s. A category
/// is nil until the session has a span that qualifies.
public struct SpeedCategories: Sendable, Hashable {
    /// Best 2 s mean; the same value as `LiveMetrics.maxSpeed2s`.
    public var peak2s: SpeedBest?
    /// Best 10 s mean; the same value as `LiveMetrics.maxSpeed10s`.
    public var best10s: SpeedBest?
    /// Mean of the five non-overlapping 10 s windows with the highest total (they may touch).
    public var best5x10s: Double?
    /// The five windows behind `best5x10s`, in time order; empty until there are five.
    public var best5x10sRanges: [ClosedRange<Double>]
    /// Fastest 100 m, 500 m and nautical mile (1852 m) of Doppler distance.
    public var best100m: SpeedBest?
    public var best500m: SpeedBest?
    public var nauticalMile: SpeedBest?
    /// Best 1 hour mean.
    public var hour: SpeedBest?
    /// Fastest 500 m run whose end is within 50 m of its start.
    public var alpha500: SpeedBest?

    public init(
        peak2s: SpeedBest? = nil, best10s: SpeedBest? = nil, best5x10s: Double? = nil,
        best5x10sRanges: [ClosedRange<Double>] = [], best100m: SpeedBest? = nil, best500m: SpeedBest? = nil,
        nauticalMile: SpeedBest? = nil, hour: SpeedBest? = nil, alpha500: SpeedBest? = nil
    ) {
        self.peak2s = peak2s
        self.best10s = best10s
        self.best5x10s = best5x10s
        self.best5x10sRanges = best5x10sRanges
        self.best100m = best100m
        self.best500m = best500m
        self.nauticalMile = nauticalMile
        self.hour = hour
        self.alpha500 = alpha500
    }

    /// The categories stored in the track summary, keyed as in docs/metrics.md, m/s.
    /// The 2 s and 10 s categories are the summary's `maxSpeed2s` and `maxSpeed10s`.
    public var summaryFields: [String: Double] {
        let fields: [(String, Double?)] = [
            ("best5x10s", best5x10s), ("best100m", best100m?.speed), ("best500m", best500m?.speed),
            ("bestNauticalMile", nauticalMile?.speed), ("best1h", hour?.speed), ("alpha500", alpha500?.speed),
        ]
        return fields.reduce(into: [:]) { result, field in
            if let value = field.1, value.isFinite { result[field.0] = value }
        }
    }

    /// Run fixes through the tracker without the live engine's GPS cleaning, for tests.
    /// Sessions use `SessionReplay`, whose engine filters fixes first. Fixes are used in
    /// time order; ones without a usable speed are skipped. `peak2s` and `best10s` use the
    /// same definitions as the session's max speeds.
    static func analyze(_ fixes: [GPSFix]) -> SpeedCategories {
        let usable = fixes.filter { fix in fix.speed.map { $0.isFinite && $0 >= 0 } ?? false }
            .sorted { $0.t < $1.t }
        var tracker = SpeedCategoryTracker()
        for fix in usable {
            tracker.ingest(t: fix.t, speed: fix.speed ?? 0, latitude: fix.latitude, longitude: fix.longitude)
        }
        var categories = tracker.categories
        // The same arithmetic as the engine's max speeds, so the values match exactly.
        let profile = SpeedProfile(usable)
        categories.peak2s = profile.bestWindow(2)
        categories.best10s = profile.bestWindow(SpeedCategoryTracker.tenSecondWindow)
        return categories
    }
}

/// Streaming speedsurfing categories over accepted fixes. Each fix costs amortised O(1)
/// plus O(windows ending in the last 10 s) for 5 × 10 s, so it runs live on the watch.
///
/// Speed is linear between fixes (the trapezoid rule), so Doppler distance is exact for
/// that model. Every span ends at a fix; its start is interpolated. A span never crosses
/// an interval longer than `maxGap` between fixes, nor a `breakRun()`.
public struct SpeedCategoryTracker: Sendable {
    /// Longest interval between fixes a span may cross, s (`SessionStats.maxSpeedGap`).
    public static let maxGap = 10.0
    public static let fiveByTenCount = 5
    public static let tenSecondWindow = 10.0
    public static let hourWindow = 3600.0
    /// Category distances, m.
    public static let distances = (short: 100.0, medium: 500.0, nauticalMile: 1852.0)
    /// Alpha: the run is `distances.medium` long and ends within this radius of its start, m.
    public static let alphaRadius = 50.0

    /// A set of non-overlapping 10 s windows and the sum of their means.
    private struct Choice: Sendable {
        var total: Double
        /// In time order.
        var ranges: [ClosedRange<Double>]
    }

    /// The best choice of j windows (j = 0...5) among the windows ending at or before `end`.
    private struct Prefix: Sendable {
        let end: Double
        let best: [Choice?]
    }

    private static let noChoices: [Choice?] =
        [Choice(total: 0, ranges: [])] + Array(repeating: nil, count: fiveByTenCount)

    // The current run, oldest first. `d` is cumulative Doppler distance from the run start.
    private var t: [Double] = []
    private var v: [Double] = []
    private var d: [Double] = []
    private var lat: [Double] = []
    private var lon: [Double] = []
    /// Index of the last position anchor in the run; alpha starts may not precede it.
    private var anchor = 0
    /// An anchor fix without a speed: the next fix in the run takes its place.
    private var pendingAnchor = false
    /// A category over a fixed distance (m) or time (s), and its best so far.
    private struct Span: Sendable {
        let length: Double
        /// Largest index j with the span's start at or after fix j; -1 until a span fits.
        var pointer = -1
        var best: SpeedBest?
    }

    private var best100m = Span(length: distances.short)
    private var best500m = Span(length: distances.medium)
    private var nauticalMile = Span(length: distances.nauticalMile)
    private var best10s = Span(length: tenSecondWindow)
    private var hour = Span(length: hourWindow)
    private var alpha500: SpeedBest?
    // 5 × 10 s, as weighted interval selection over windows in end order. `recent` holds
    // the windows a future window could still overlap; `settled` is the best choice among
    // the windows before them, and `latest` among all windows so far.
    private var recent: [Prefix] = []
    private var recentStart = 0
    private var settled = noChoices
    private var latest = noChoices

    public init() {}

    /// End the current run: no span may cross this point (a removed interval).
    public mutating func breakRun() {
        t.removeAll(keepingCapacity: true)
        v.removeAll(keepingCapacity: true)
        d.removeAll(keepingCapacity: true)
        lat.removeAll(keepingCapacity: true)
        lon.removeAll(keepingCapacity: true)
        anchor = 0
        pendingAnchor = false
        best100m.pointer = -1
        best500m.pointer = -1
        nauticalMile.pointer = -1
        best10s.pointer = -1
        hour.pointer = -1
    }

    /// Mark an accepted anchor fix that has no Doppler speed: alpha may not start before
    /// the next fix with one.
    public mutating func noteAnchor() {
        pendingAnchor = true
    }

    /// Add an accepted fix with a Doppler speed. `isAnchor` marks a fix the GPS filter
    /// accepted after a position jump: alpha's start-to-end check may not span it.
    public mutating func ingest(
        t time: Double, speed: Double, latitude: Double, longitude: Double, isAnchor: Bool = false
    ) {
        guard time.isFinite, speed.isFinite, speed >= 0, latitude.isFinite, longitude.isFinite else { return }
        if let last = t.last {
            guard time > last else { return }
            if time - last > Self.maxGap { breakRun() }
        }
        if let last = t.indices.last {
            d.append(d[last] + (v[last] + speed) / 2 * (time - t[last]))
        } else {
            d.append(0)
        }
        t.append(time)
        v.append(speed)
        lat.append(latitude)
        lon.append(longitude)
        let n = t.count - 1
        if isAnchor || pendingAnchor { anchor = n }
        pendingAnchor = false

        best100m = updatedDistance(best100m)
        best500m = updatedDistance(best500m)
        nauticalMile = updatedDistance(nauticalMile)
        updateAlpha()
        let (tenSeconds, mean) = updatedTime(best10s)
        best10s = tenSeconds
        if let mean { addWindow(mean: mean, range: (time - Self.tenSecondWindow)...time) }
        hour = updatedTime(hour).span
        compact()
    }

    public var categories: SpeedCategories {
        let five = latest[Self.fiveByTenCount]
        return SpeedCategories(
            best10s: best10s.best,
            best5x10s: five.map { $0.total / Double(Self.fiveByTenCount) },
            best5x10sRanges: five?.ranges ?? [],
            best100m: best100m.best, best500m: best500m.best, nauticalMile: nauticalMile.best, hour: hour.best,
            alpha500: alpha500)
    }

    // MARK: - Spans

    /// Ties keep the earlier span. Spans of equal speed can differ in the last bits from
    /// the root solve, so a later one must be faster by more than rounding.
    private static func improves(_ speed: Double, on best: SpeedBest?) -> Bool {
        guard let best else { return true }
        return speed > best.speed * (1 + 1e-12)
    }

    /// Doppler distance from fix i to `time` within segment i (t[i] <= time <= t[i+1]).
    private func distance(from i: Int, to time: Double) -> Double {
        let x = time - t[i]
        guard x > 0 else { return 0 }
        let h = t[i + 1] - t[i]
        return v[i] * x + (v[i + 1] - v[i]) / (2 * h) * x * x
    }

    /// The time in segment i at which cumulative distance reaches `target`
    /// (d[i] <= target <= d[i+1]).
    private func time(in i: Int, reaching target: Double) -> Double {
        let h = t[i + 1] - t[i]
        let need = target - d[i]
        guard need > 0 else { return t[i] }
        // need = v0 x + a x² with a = (v1 - v0) / 2h. The stable root avoids cancellation.
        let a = (v[i + 1] - v[i]) / (2 * h)
        let b = v[i]
        let root = max(0, b * b + 4 * a * need).squareRoot()
        let x = b + root > 0 ? 2 * need / (b + root) : h
        return t[i] + min(h, max(0, x))
    }

    /// Advance a distance pointer to the latest start of a span of `distance` ending at
    /// the newest fix, and return that start time.
    private func advance(_ pointer: inout Int, distance: Double) -> Double? {
        let n = t.count - 1
        let target = d[n] - distance
        while pointer + 1 < n, d[pointer + 1] <= target { pointer += 1 }
        guard pointer >= 0 else { return nil }
        return time(in: pointer, reaching: target)
    }

    private func updatedDistance(_ span: Span) -> Span {
        var span = span
        guard let start = advance(&span.pointer, distance: span.length), let end = t.last, end > start else {
            return span
        }
        let speed = span.length / (end - start)
        if Self.improves(speed, on: span.best) { span.best = SpeedBest(speed: speed, range: start...end) }
        return span
    }

    private mutating func updateAlpha() {
        let p500 = best500m.pointer
        guard p500 >= anchor, let end = t.last else { return }
        let target = d[t.count - 1] - Self.distances.medium
        guard target >= d[p500] else { return }
        let start = time(in: p500, reaching: target)
        guard end > start else { return }
        // Interpolate the start position along the segment; at these distances a straight
        // line between two fixes is well inside GPS noise.
        let f = (start - t[p500]) / (t[p500 + 1] - t[p500])
        let startLat = lat[p500] + (lat[p500 + 1] - lat[p500]) * f
        // Across the antimeridian, interpolate the short way round.
        var dLon = lon[p500 + 1] - lon[p500]
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        let startLon = lon[p500] + dLon * f
        let gap = Geo.distance(lat1: startLat, lon1: startLon, lat2: lat[t.count - 1], lon2: lon[t.count - 1])
        guard gap <= Self.alphaRadius else { return }
        let speed = Self.distances.medium / (end - start)
        if Self.improves(speed, on: alpha500) { alpha500 = SpeedBest(speed: speed, range: start...end) }
    }

    /// Update a fixed-time best for the window ending at the newest fix, with its mean.
    private func updatedTime(_ span: Span) -> (span: Span, mean: Double?) {
        var span = span
        let n = t.count - 1
        let start = t[n] - span.length
        guard n > 0, t[0] <= start else { return (span, nil) }
        while span.pointer + 1 < n, t[span.pointer + 1] <= start { span.pointer += 1 }
        span.pointer = max(0, span.pointer)
        let mean = (d[n] - d[span.pointer] - distance(from: span.pointer, to: start)) / span.length
        if Self.improves(mean, on: span.best) { span.best = SpeedBest(speed: mean, range: start...t[n]) }
        return (span, mean)
    }

    // MARK: - 5 × 10 s

    /// Add the 10 s window ending at the newest fix. The best choice of j windows is
    /// either the best without it, or the best j − 1 among windows ending by its start,
    /// plus it. Windows end in time order, so those that can no longer overlap a future
    /// window move from `recent` into `settled`. Ties keep the earlier choice.
    private mutating func addWindow(mean: Double, range: ClosedRange<Double>) {
        while recentStart < recent.count, recent[recentStart].end <= range.lowerBound {
            settled = recent[recentStart].best
            recentStart += 1
        }
        if recentStart > 64, recentStart * 2 > recent.count {
            recent.removeFirst(recentStart)
            recentStart = 0
        }
        var best = latest
        for j in 1...Self.fiveByTenCount {
            guard let before = settled[j - 1] else { continue }
            let total = before.total + mean
            if best[j].map({ total > $0.total * (1 + 1e-12) }) ?? true {
                best[j] = Choice(total: total, ranges: before.ranges + [range])
            }
        }
        latest = best
        recent.append(Prefix(end: range.upperBound, best: best))
    }

    // MARK: - Memory

    /// Drop fixes no future span can start from, in batches.
    private mutating func compact() {
        let keep = min(
            best100m.pointer, best500m.pointer, nauticalMile.pointer, best10s.pointer, hour.pointer)
        guard keep > 2048 else { return }
        t.removeFirst(keep)
        v.removeFirst(keep)
        d.removeFirst(keep)
        lat.removeFirst(keep)
        lon.removeFirst(keep)
        anchor = max(0, anchor - keep)
        best100m.pointer -= keep
        best500m.pointer -= keep
        nauticalMile.pointer -= keep
        best10s.pointer -= keep
        hour.pointer -= keep
    }
}

extension SpeedProfile {
    /// The best mean over `window` and its range, for windows that end at a fix (as live).
    func bestWindow(_ window: Double) -> SpeedBest? {
        guard t.count >= 2, window > 0 else { return nil }
        var best: SpeedBest?
        for end in t {
            let start = end - window
            guard let area = integral(from: start, to: end, maxGap: window) else { continue }
            let mean = area / window
            if !(best.map { $0.speed >= mean } ?? false) { best = SpeedBest(speed: mean, range: start...end) }
        }
        return best
    }
}
