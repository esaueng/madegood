/// Post-session paddling stroke analysis (docs/metrics.md "Strokes"): the stroke list,
/// stroke rate over time, average rate, distance per stroke and side switches.
///
/// It runs `StrokeDetector` over the recording's motion stream; tracks do not keep motion,
/// so this needs the raw recording.
public struct StrokeAnalysis: Sendable, Hashable {
    public struct Stroke: Sendable, Hashable {
        /// s, on the caller's clock (the replay clock for a selection).
        public var t: Double
        /// 0 or 1 for canoe and SUP; nil for kayak.
        public var side: Int?
    }

    public struct RatePoint: Sendable, Hashable {
        public var t: Double
        /// Strokes per minute over this cycle and up to three before it (see
        /// `StrokeDetector`'s rate).
        public var strokeRate: Double
    }

    public let sport: Sport
    public let strokes: [Stroke]
    /// Strokes over the time spent in counted cycles, per minute; nil with fewer than two
    /// cycles in a row.
    public let averageStrokeRate: Double?
    public let rateSeries: [RatePoint]
    /// Distance over stroke count, m; nil without strokes or distance.
    public let distancePerStroke: Double?
    /// Changes of paddling side between consecutive strokes (canoe, SUP).
    public let sideSwitches: Int
    /// Share of strokes on side 0 (canoe, SUP), 0–1; nil for kayak or without strokes.
    public let sideBalance: Double?

    public var strokeCount: Int { strokes.count }

    /// Every wrist cycle in `motion` (session time), for `init(cycles:…)`. Detect once and
    /// keep the cycles, rather than the motion stream, to re-analyze after a trim.
    public static func cycles(
        in motion: [MotionSample], sport: Sport, config: StrokeDetector.Config = StrokeDetector.Config()
    ) -> [StrokeDetector.Cycle] {
        var detector = StrokeDetector(sport: sport, config: config, recordsCycles: true)
        for sample in motion { detector.ingest(sample) }
        // Close the last bin, so a cycle that ended in it is not lost.
        if var closing = motion.last {
            closing.t += config.binInterval
            detector.ingest(closing)
        }
        return detector.cycles
    }

    /// Analyzes `motion` (session time) for `sport`. See `init(cycles:…)`.
    public init(
        motion: [MotionSample], sport: Sport, distance: Double?, retained: [ClosedRange<Double>]? = nil,
        clock: (Double) -> Double = { $0 }, config: StrokeDetector.Config = StrokeDetector.Config()
    ) {
        self.init(
            cycles: Self.cycles(in: motion, sport: sport, config: config), sport: sport, distance: distance,
            retained: retained, clock: clock)
    }

    /// Analyzes detected cycles. Only cycles inside `retained` count when it is given, and
    /// only periods with both ends in the same range count toward rates. `clock` maps
    /// session time to the output clock. `distance` is the distance paddled, m.
    public init(
        cycles detected: [StrokeDetector.Cycle], sport: Sport, distance: Double?,
        retained: [ClosedRange<Double>]? = nil, clock: (Double) -> Double = { $0 }
    ) {
        var cycles: [StrokeDetector.Cycle] = []
        for var cycle in detected {
            if let retained {
                guard let owner = retained.first(where: { $0.contains(cycle.t) }) else { continue }
                if let period = cycle.period, !owner.contains(cycle.t - period) { cycle.period = nil }
            }
            cycles.append(cycle)
        }

        let strokesPerCycle = sport == .kayak ? 2 : 1
        var strokes: [Stroke] = []
        var rates: [RatePoint] = []
        var recent: [Double] = []
        var countedTime = 0.0
        var countedStrokes = 0
        for (index, cycle) in cycles.enumerated() {
            strokes.append(Stroke(t: clock(cycle.t), side: cycle.side))
            if strokesPerCycle == 2 {
                // The other blade's stroke, half a cycle later.
                let next = index + 1 < cycles.count ? cycles[index + 1].period : nil
                let half = (next ?? cycle.period ?? 1.5) / 2
                strokes.append(Stroke(t: clock(cycle.t + half), side: nil))
            }
            if let period = cycle.period {
                countedTime += period
                countedStrokes += strokesPerCycle
                recent.append(period)
                if recent.count > 4 { recent.removeFirst() }
                if let rate = StrokeDetector.rate(periods: recent, strokesPerCycle: strokesPerCycle) {
                    rates.append(RatePoint(t: clock(cycle.t), strokeRate: rate))
                }
            } else {
                recent.removeAll()
            }
        }
        self.sport = sport
        self.strokes = strokes
        averageStrokeRate = countedStrokes >= 2 * strokesPerCycle ? 60 * Double(countedStrokes) / countedTime : nil
        rateSeries = rates
        if let distance, distance > 0, !strokes.isEmpty {
            distancePerStroke = distance / Double(strokes.count)
        } else {
            distancePerStroke = nil
        }
        let sides = strokes.compactMap(\.side)
        sideSwitches = zip(sides, sides.dropFirst()).filter { $0 != $1 }.count
        sideBalance = sides.isEmpty ? nil : Double(sides.filter { $0 == 0 }.count) / Double(sides.count)
    }

    /// Strokes for a selection of a recording (trimmed or not), on the replay clock, with
    /// distance per stroke from the selection's moving distance.
    public init(session: RawSession, selection: SessionSelection) {
        self.init(
            cycles: Self.cycles(in: session.motion, sport: session.meta.sport), sport: session.meta.sport,
            selection: selection)
    }

    /// As `init(session:selection:)`, from cycles detected earlier with `cycles(in:sport:)`.
    public init(cycles: [StrokeDetector.Cycle], sport: Sport, selection: SessionSelection) {
        self.init(
            cycles: cycles, sport: sport, distance: selection.replay.metrics.distance,
            retained: selection.retainedRanges, clock: { selection.replayTime(forSourceTime: $0) })
    }
}
