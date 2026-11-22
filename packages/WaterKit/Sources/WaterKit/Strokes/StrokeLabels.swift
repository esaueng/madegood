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
    /// excluded segment or at a gap longer than `maxCyclePeriod` per cycle, and the rate is
    /// the intervals within bouts of at least three strokes over their total time. Nil when
    /// no such bout exists.
    public func strokeRate(sport: Sport) -> Double? {
        let perCycle = sport == .kayak ? 2.0 : 1.0
        let maxGap = Self.maxCyclePeriod / perCycle
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
        for (a, b) in zip(strokes, strokes.dropFirst()) {
            let gap = b.t - a.t
            let split = gap <= 0 || gap > maxGap || excluded.contains { $0.overlaps(a.t, b.t) }
            if split {
                closeBout()
            } else {
                boutIntervals += 1
                boutTime += gap
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
