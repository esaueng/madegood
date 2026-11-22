/// What a person needs to label a recording's strokes: the detector's candidates, the
/// signal they were found in, GPS speed, and where session detail leaves strokes out.
/// `waterkit-label` turns it into a draft label file and a review page.
public struct StrokeReview: Sendable {
    public struct Candidate: Sendable, Hashable {
        /// s since the session start.
        public var t: Double
        public var side: Int?
        /// Whether session detail counts this stroke (it is in moving time).
        public var counted: Bool
    }

    public struct SpeedPoint: Sendable, Hashable {
        public var t: Double
        /// Doppler speed, m/s.
        public var speed: Double
    }

    public var sport: Sport
    /// s, the end of the last sample, fix or event.
    public var duration: Double
    /// Every stroke the detector found outside manual pauses, counted by session detail or not.
    public var candidates: [Candidate]
    /// Session-time ranges where session detail counts no strokes: auto-pauses, vehicle
    /// legs and manual pauses.
    public var notCounted: [ClosedRange<Double>]
    public var speed: [SpeedPoint]
    public var signal: StrokeReviewSignal

    /// Analyzes a paddling recording read with its motion.
    public init(session: RawSession) throws {
        sport = session.meta.sport
        let detection = StrokeAnalysis.detect(session: session)
        let selection = try SessionSelection(session: session)
        let moving = StrokeAnalysis.movingRanges(of: selection)
        let pauses = Self.manualPauses(session.events)
        // Untrimmed, the selection's source clock is session time.
        func isCounted(_ t: Double) -> Bool {
            moving.contains { $0.contains(t) } && !pauses.contains { t >= $0.lowerBound && t < $0.upperBound }
        }
        candidates = detection.strokes.map { Candidate(t: $0.t, side: $0.side, counted: isCounted($0.t)) }
        let end = max(
            selection.duration, session.duration, session.motion.last?.t ?? 0, session.gps.last?.t ?? 0)
        duration = end
        notCounted = StrokeAnalysis.ranges([0...end], excluding: moving) + pauses
        speed = session.gps.compactMap { fix in
            guard let value = fix.speed, value >= 0, value.isFinite else { return nil }
            return SpeedPoint(t: fix.t, speed: value)
        }
        signal = StrokeReviewSignal(motion: session.motion, cycleTimes: detection.cycles.map(\.t))
    }

    /// The detector's candidates as unreviewed labels. They are a starting point for a
    /// person, never ground truth.
    public var draft: StrokeLabels {
        StrokeLabels(strokes: candidates.map { StrokeLabels.Stroke(t: $0.t, side: $0.side) })
    }

    /// The user's own pause and resume events as [pause, resume) ranges.
    static func manualPauses(_ events: [SessionEvent]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var since: Double?
        for event in events where event.data?["auto"] != .bool(true) {
            if event.type == .pause, since == nil { since = event.t }
            if event.type == .resume, let start = since {
                ranges.append(start...max(start, event.t))
                since = nil
            }
        }
        if let start = since { ranges.append(start...(events.last?.t ?? start)) }
        return ranges
    }
}

/// Scores the app against reviewed stroke labels the way the accuracy tests do: the count
/// and average rate session detail shows against the labelled truth (PLAN §5).
public struct StrokeScore: Sendable, Hashable {
    /// PLAN §5: stroke count within ±3 %.
    public static let countTolerance = 0.03
    /// PLAN §5: stroke rate within ±2 SPM.
    public static let rateTolerance = 2.0
    /// Longest matching window for the per-stroke breakdown, s. Each labelled stroke matches
    /// within 0.45 × the time to its nearest labelled neighbour, at most this: kayak's
    /// second stroke is placed half a cycle after the first, which can be several tenths of
    /// a second from where the other blade went in.
    public static let matchWindow = 0.6

    public var truthCount: Int
    public var truthRate: Double?
    public var appCount: Int
    public var appRate: Double?
    /// Labelled strokes with a session-detail stroke within `matchWindow`, one to one.
    public var matched: Int
    /// Labelled strokes session detail does not have.
    public var missed: Int
    /// Session-detail strokes with no labelled stroke.
    public var extra: Int
    /// Session-detail strokes inside excluded segments (counted while not paddling).
    public var extraInExcluded: Int

    /// (app − truth) / truth; nil without labelled strokes.
    public var countError: Double? {
        truthCount > 0 ? Double(appCount - truthCount) / Double(truthCount) : nil
    }

    /// app − truth, SPM.
    public var rateError: Double? {
        guard let truthRate, let appRate else { return nil }
        return appRate - truthRate
    }

    public var countPasses: Bool { countError.map { abs($0) <= Self.countTolerance } ?? false }
    public var ratePasses: Bool { rateError.map { abs($0) <= Self.rateTolerance } ?? false }

    public init(labels: StrokeLabels, session: RawSession) throws {
        let selection = try SessionSelection(session: session)
        let app = StrokeAnalysis(session: session, selection: selection)
        // Session detail's strokes are on the replay clock; labels are on the source clock.
        let appTimes = app.strokes.map { selection.sourceTime(forReplayTime: $0.t) }
        self.init(labels: labels, sport: session.meta.sport, appTimes: appTimes, appRate: app.averageStrokeRate)
    }

    init(labels: StrokeLabels, sport: Sport, appTimes: [Double], appRate: Double?) {
        truthCount = labels.count
        truthRate = labels.strokeRate(sport: sport)
        appCount = appTimes.count
        self.appRate = appRate
        let truth = labels.strokes.map(\.t)
        let app = appTimes.sorted()
        var used = [Bool](repeating: false, count: app.count)
        var matched = 0
        var lower = 0
        for (position, t) in truth.enumerated() {
            var window = Self.matchWindow
            if position > 0 { window = min(window, 0.45 * (t - truth[position - 1])) }
            if position + 1 < truth.count { window = min(window, 0.45 * (truth[position + 1] - t)) }
            while lower < app.count, app[lower] < t - Self.matchWindow { lower += 1 }
            var best: Int?
            var index = lower
            while index < app.count, app[index] <= t + window {
                guard app[index] >= t - window else {
                    index += 1
                    continue
                }
                if !used[index], best.map({ abs(app[index] - t) < abs(app[$0] - t) }) ?? true { best = index }
                index += 1
            }
            if let best {
                used[best] = true
                matched += 1
            }
        }
        self.matched = matched
        missed = truth.count - matched
        extra = app.count - matched
        extraInExcluded = app.filter { t in labels.excluded.contains { $0.contains(t) } }.count
    }
}
