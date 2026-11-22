/// Post-session paddling stroke analysis (docs/metrics.md "Strokes"): the stroke list,
/// stroke rate over time, average rate, distance per stroke and side switches.
///
/// It runs `StrokeDetector` over the recording's motion stream; tracks do not keep motion,
/// so this needs the raw recording. Detection runs on one monotonic clock (the motion
/// sensor's monotonic time when the recording has it), so a wall-clock correction cannot reorder a
/// pause and the strokes around it. Results are then put on the session clock.
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
    /// Fixed-count intervals on the replay clock, available when analyzing a selection.
    public private(set) var strokeIntervals: [PaddlingStrokeInterval] = []

    public var strokeCount: Int { strokes.count }

    /// Strokes found in a recording, on the session clock: detect once and keep this (not
    /// the motion stream) to re-analyze after a trim.
    public struct Detection: Sendable, Hashable {
        /// Every counted wrist cycle.
        public var cycles: [StrokeDetector.Cycle]
        /// Every counted stroke: two per kayak cycle, none inside a manual pause.
        public var strokes: [Stroke]

        public init(cycles: [StrokeDetector.Cycle], strokes: [Stroke]) {
            self.cycles = cycles
            self.strokes = strokes
        }
    }

    /// Detects strokes in `motion`. `events` carry the user's pause and resume (auto-pause
    /// events are ignored) on the same clock as the motion. `toSessionTime` maps that clock
    /// to session time.
    public static func detect(
        motion: [MotionSample], sport: Sport, events: [SessionEvent] = [],
        config: StrokeDetector.Config = StrokeDetector.Config(),
        toSessionTime: (Double) -> Double = { $0 }
    ) -> Detection {
        var detector = StrokeDetector(sport: sport, config: config, recordsCycles: true)
        let pauses = events.filter { $0.type == .pause || $0.type == .resume }
        var next = pauses.startIndex
        for sample in motion {
            while next < pauses.endIndex, pauses[next].t <= sample.t {
                detector.ingest(pauses[next])
                next += 1
            }
            detector.ingest(sample)
        }
        // Close the last bin, so a cycle that ended in it is not lost.
        if var closing = motion.last {
            closing.t += config.binInterval
            detector.ingest(closing)
        }
        for event in pauses[next...] { detector.ingest(event) }
        let cycles = detector.cycles
        let strokes = expand(cycles, strokesPerCycle: detector.strokesPerCycle) { detector.isPaused(at: $0) }
        return Detection(
            cycles: cycles.map { cycle in
                var cycle = cycle
                cycle.t = toSessionTime(cycle.t)
                return cycle
            },
            strokes: strokes.map { Stroke(t: toSessionTime($0.t), side: $0.side) })
    }

    /// Detects strokes in a recording. Motion read from files carries its monotonic time,
    /// and the session's pause events are kept on that clock, so detection runs on the
    /// monotonic clock and is then converted to session time with the clock anchors.
    public static func detect(session: RawSession, config: StrokeDetector.Config = StrokeDetector.Config()) -> Detection {
        let sport = session.meta.sport
        guard let pauseEvents = session.pauseEventsOnMonotonicClock, !session.motion.isEmpty,
            session.motion.allSatisfy({ $0.monotonic != nil })
        else {
            return detect(motion: session.motion, sport: sport, events: session.events, config: config)
        }
        let origin = session.monotonicStart
        // Monotonic order is recording order, whatever the wall clock did.
        let motion = session.motion.map { sample in
            var sample = sample
            sample.t = (sample.monotonic ?? 0) - origin
            return sample
        }.sorted { $0.t < $1.t }
        let clock = SessionClock(
            startedAt: session.meta.startedAt, anchors: session.clockAnchors.sorted { $0.mono < $1.mono })
        return detect(motion: motion, sport: sport, events: pauseEvents, config: config) {
            clock.fromMono($0 + origin)
        }
    }

    /// Strokes in `cycles` outside every `excluded` interval, counted the way session detail
    /// counts them (`init(session:selection:)`): kayak cycles expanded into their two strokes
    /// first, then a stroke left out when it falls in a manual pause (`isPaused`, on the
    /// cycles' clock) or in an excluded interval (on session time, which `toSessionTime` maps
    /// the cycles' clock to), its start included and its end not. For the live count, with
    /// the engine's `autoPausedIntervals`.
    public static func strokeCount(
        cycles: [StrokeDetector.Cycle], strokesPerCycle: Int, excluding excluded: [ClosedRange<Double>],
        isPaused: (Double) -> Bool = { _ in false }, toSessionTime: (Double) -> Double = { $0 }
    ) -> Int {
        func isExcluded(_ t: Double) -> Bool {
            let session = toSessionTime(t)
            return excluded.contains { $0.lowerBound <= session && session < $0.upperBound }
        }
        return expand(cycles, strokesPerCycle: strokesPerCycle) { isPaused($0) || isExcluded($0) }.count
    }

    /// Strokes from cycles: the cycle's own, plus for kayak the other blade's stroke half a
    /// cycle later. A stroke inside a manual pause is left out.
    static func expand(
        _ cycles: [StrokeDetector.Cycle], strokesPerCycle: Int, isPaused: (Double) -> Bool = { _ in false }
    ) -> [Stroke] {
        var strokes: [Stroke] = []
        for (index, cycle) in cycles.enumerated() {
            if !isPaused(cycle.t) { strokes.append(Stroke(t: cycle.t, side: cycle.side)) }
            guard strokesPerCycle == 2 else { continue }
            let next = index + 1 < cycles.count ? cycles[index + 1].period : nil
            let half = (next ?? cycle.period ?? 1.5) / 2
            if !isPaused(cycle.t + half) { strokes.append(Stroke(t: cycle.t + half, side: nil)) }
        }
        return strokes
    }

    /// Analyzes `motion` (session time) for `sport`. See `init(detection:…)`.
    public init(
        motion: [MotionSample], sport: Sport, events: [SessionEvent] = [], distance: Double?,
        retained: [ClosedRange<Double>]? = nil, clock: (Double) -> Double = { $0 },
        config: StrokeDetector.Config = StrokeDetector.Config()
    ) {
        self.init(
            detection: Self.detect(motion: motion, sport: sport, events: events, config: config), sport: sport,
            distance: distance, retained: retained, clock: clock)
    }

    /// Analyzes a detection. Only strokes inside `retained` count when it is given (each on
    /// its own time), and only periods with both ends in the same range count toward rates.
    /// `clock` maps session time to the output clock. `distance` is the distance paddled, m.
    public init(
        detection: Detection, sport: Sport, distance: Double?, retained: [ClosedRange<Double>]? = nil,
        clock: (Double) -> Double = { $0 }
    ) {
        let strokesPerCycle = sport == .kayak ? 2 : 1
        func isRetained(_ t: Double) -> Bool { retained?.contains { $0.contains(t) } ?? true }
        let strokes = detection.strokes.filter { isRetained($0.t) }.map { Stroke(t: clock($0.t), side: $0.side) }

        var rates: [RatePoint] = []
        var recent: [Double] = []
        var countedTime = 0.0
        var countedStrokes = 0
        for var cycle in detection.cycles {
            if let retained {
                guard let owner = retained.first(where: { $0.contains(cycle.t) }) else { continue }
                if let period = cycle.period, !owner.contains(cycle.t - period) { cycle.period = nil }
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

    /// The selection's retained ranges (source clock) without its auto-paused intervals and
    /// vehicle legs.
    static func movingRanges(of selection: SessionSelection) -> [ClosedRange<Double>] {
        let paused = selection.replay.autoPausedIntervals.map { interval in
            let start = selection.sourceTime(forReplayTime: interval.lowerBound)
            return start...max(start, selection.sourceTime(forReplayTime: interval.upperBound))
        }
        return ranges(selection.retainedRanges, excluding: paused)
    }

    /// `ranges` with the sorted `paused` intervals cut out. A time at a pause's start is
    /// out and one at its resume is in, as for manual pauses.
    static func ranges(
        _ ranges: [ClosedRange<Double>], excluding paused: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges {
            var start = range.lowerBound
            var open = true
            for pause in paused where pause.upperBound >= range.lowerBound && pause.lowerBound <= range.upperBound {
                if pause.lowerBound > start { result.append(start...pause.lowerBound.nextDown) }
                if pause.upperBound >= range.upperBound {
                    open = false
                    break
                }
                start = max(start, pause.upperBound)
            }
            if open { result.append(start...range.upperBound) }
        }
        return result
    }

    /// Strokes for a selection of a recording (trimmed or not), on the replay clock, with
    /// distance per stroke from the selection's moving distance. Like distance, strokes and
    /// rates count only in moving time: not in a manual pause or auto-pause, or a vehicle leg.
    public init(session: RawSession, selection: SessionSelection) {
        self.init(detection: Self.detect(session: session), sport: session.meta.sport, selection: selection)
    }

    /// As `init(session:selection:)`, from a detection made earlier with `detect(session:)`.
    public init(detection: Detection, sport: Sport, selection: SessionSelection) {
        self.init(
            detection: detection, sport: sport, distance: selection.replay.metrics.distance,
            retained: Self.movingRanges(of: selection), clock: { selection.replayTime(forSourceTime: $0) })
        if sport.isPaddling {
            strokeIntervals = PaddlingStrokeInterval.makeIntervals(
                strokes: strokes, movement: selection.replay.paddlingMovement,
                start: selection.replayRanges[0].lowerBound)
        }
    }
}
