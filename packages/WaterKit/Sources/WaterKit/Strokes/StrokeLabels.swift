/// Stroke-by-stroke ground truth for a paddling fixture: the `strokeTimes` and `excluded`
/// fields of `labels.json` (fixtures/README.md), and the count and rate derived from them.
///
/// Times are seconds since the session start, the clock of `RawSession.motion` and of
/// `StrokeAnalysis.detect(session:)`. Anonymizing a recording keeps that clock, so labels
/// made on the original recording stay valid for the anonymized fixture.
public struct StrokeLabels: Sendable, Hashable, Codable {
    public struct Stroke: Sendable, Hashable, Codable {
        /// s since the session start.
        public var t: Double
        /// 0 or 1 when known (canoe, SUP), with the detector's meaning: side 0 is the side
        /// paddled first. Nil when unknown, as for kayak.
        public var side: Int?

        public init(t: Double, side: Int? = nil) {
            self.t = t
            self.side = side
        }
    }

    /// A stretch that is not paddling: getting in, drifting, a rest, carrying the boat. No
    /// labelled stroke lies in one, and no rate period spans one.
    public struct Segment: Sendable, Hashable, Codable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        func contains(_ t: Double) -> Bool { t >= start && t <= end }
        func overlaps(_ a: Double, _ b: Double) -> Bool { start < b && end > a }
    }

    /// Every stroke a person confirmed, in time order.
    public var strokes: [Stroke]
    public var excluded: [Segment]

    enum CodingKeys: String, CodingKey {
        case strokes = "strokeTimes"
        case excluded
    }

    public init(strokes: [Stroke], excluded: [Segment] = []) {
        self.strokes = strokes.sorted { $0.t < $1.t }
        self.excluded = excluded.sorted { $0.start < $1.start }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let strokes = try container.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        let excluded = try container.decodeIfPresent([Segment].self, forKey: .excluded) ?? []
        self.init(strokes: strokes, excluded: excluded)
    }

    /// The longest time between two strokes of one bout, per wrist cycle, s. It matches the
    /// detector's pause (docs/metrics.md "Strokes"): 2 s between kayak strokes, 4 s for
    /// canoe and SUP.
    public static let maxCyclePeriod = 4.0

    /// Strokes counted in the truth: every labelled stroke.
    public var count: Int { strokes.count }

    /// Average strokes per minute while paddling: strokes are split into bouts at an
    /// excluded segment or a pause, and the rate is the intervals within bouts of at least
    /// three strokes over their total time. Nil when no such bout exists.
    ///
    /// A pause is a wrist cycle longer than `maxCyclePeriod`. For canoe and SUP a cycle is
    /// one stroke, so a gap over 4 s. For kayak it is two strokes, and the labels do not say
    /// which strokes pair: a gap over 2 s is a pause when it makes a cycle over 4 s with
    /// either neighbouring gap that is paddling itself (not a pause on its own, not across
    /// an excluded segment). Blades that are not evenly spaced (0.9 s and 2.1 s) stay one
    /// bout, even next to a stop, and a 3.25 s stop after a 0.5 s gap still splits at the stop.
    public func strokeRate(sport: Sport) -> Double? {
        guard strokes.count >= 2 else { return nil }
        let gaps = zip(strokes, strokes.dropFirst()).map { $1.t - $0.t }
        func crossesExcluded(_ index: Int) -> Bool {
            excluded.contains { $0.overlaps(strokes[index].t, strokes[index + 1].t) }
        }
        func isPauseAlone(_ index: Int) -> Bool {
            gaps[index] <= 0 || gaps[index] > Self.maxCyclePeriod || crossesExcluded(index)
        }
        func isPause(_ index: Int) -> Bool {
            let gap = gaps[index]
            if isPauseAlone(index) { return true }
            guard sport == .kayak, gap > Self.maxCyclePeriod / 2 else { return false }
            let neighbours = [index - 1, index + 1].filter { gaps.indices.contains($0) && !isPauseAlone($0) }
            if neighbours.isEmpty { return true }
            return neighbours.contains { gap + gaps[$0] > Self.maxCyclePeriod }
        }
        var intervals = 0
        var time = 0.0
        var boutIntervals = 0
        var boutTime = 0.0
        func closeBout() {
            if boutIntervals >= 2 {
                intervals += boutIntervals
                time += boutTime
            }
            boutIntervals = 0
            boutTime = 0
        }
        for index in gaps.indices {
            if isPause(index) {
                closeBout()
            } else {
                boutIntervals += 1
                boutTime += gaps[index]
            }
        }
        closeBout()
        guard intervals > 0, time > 0 else { return nil }
        return 60 * Double(intervals) / time
    }

    /// Problems that make these labels unusable for a recording `duration` s long; empty
    /// when they pass.
    public func problems(duration: Double) -> [String] {
        var problems: [String] = []
        let limit = duration + 1
        if strokes.contains(where: { !$0.t.isFinite || $0.t < 0 || $0.t > limit }) {
            problems.append("stroke times must lie within the recording (0–\(Int(duration.rounded())) s)")
        }
        if strokes.contains(where: { $0.side != nil && $0.side != 0 && $0.side != 1 }) {
            problems.append("a stroke's side must be 0 or 1")
        }
        let duplicates = zip(strokes, strokes.dropFirst()).filter { $1.t - $0.t < 0.05 }.count
        if duplicates > 0 { problems.append("\(duplicates) strokes are within 0.05 s of the previous one") }
        for segment in excluded {
            if !(segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.start < segment.end
                && segment.end <= limit)
            {
                problems.append("excluded segment \(segment.start)–\(segment.end) is not a range within the recording")
            }
        }
        let inside = strokes.filter { stroke in excluded.contains { $0.contains(stroke.t) } }.count
        if inside > 0 { problems.append("\(inside) strokes lie in excluded segments") }
        return problems
    }
}
