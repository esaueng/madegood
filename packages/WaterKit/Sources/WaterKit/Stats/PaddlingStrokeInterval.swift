/// A fixed-count paddling interval on the selected track's replay clock.
/// Distance is in metres, and time is in seconds.
public struct PaddlingStrokeInterval: Sendable, Hashable {
    public static let targetStrokeCount = 100

    /// 1-based, from the start of the selected track.
    public let index: Int
    public let strokeCount: Int
    public let elapsedRange: ClosedRange<Double>
    /// Contributing portions of observed moving steps. Empty without moving GPS data.
    public let movingRanges: [ClosedRange<Double>]
    public let movingTime: Double
    public let distance: Double

    public var isComplete: Bool { strokeCount == Self.targetStrokeCount }
    public var averageSpeed: Double? { movingTime > 0 ? distance / movingTime : nil }

    static func makeIntervals(
        strokes: [StrokeAnalysis.Stroke], movement: [SessionEngine.MovementInterval], start: Double
    ) -> [Self] {
        let times = strokes.map(\.t).sorted()
        var intervals: [Self] = []
        var lowerBound = start
        var nextStep = movement.startIndex
        for firstStroke in stride(from: 0, to: times.count, by: targetStrokeCount) {
            let endIndex = min(firstStroke + targetStrokeCount, times.count)
            let upperBound = times[endIndex - 1]
            var ranges: [ClosedRange<Double>] = []
            var distance = 0.0
            while nextStep < movement.endIndex {
                let step = movement[nextStep]
                guard step.elapsedRange.lowerBound < upperBound else { break }
                let lower = max(lowerBound, step.elapsedRange.lowerBound)
                let upper = min(upperBound, step.elapsedRange.upperBound)
                if lower < upper {
                    distance += step.distance * ((upper - lower) / step.duration)
                    if let last = ranges.last, last.upperBound == lower {
                        ranges[ranges.count - 1] = last.lowerBound...upper
                    } else {
                        ranges.append(lower...upper)
                    }
                }
                // A single observed step can straddle adjacent stroke intervals.
                guard step.elapsedRange.upperBound <= upperBound else { break }
                nextStep += 1
            }
            intervals.append(
                Self(
                    index: intervals.count + 1, strokeCount: endIndex - firstStroke,
                    elapsedRange: lowerBound...upperBound, movingRanges: ranges,
                    movingTime: ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, distance: distance))
            lowerBound = upperBound
        }
        return intervals
    }
}
