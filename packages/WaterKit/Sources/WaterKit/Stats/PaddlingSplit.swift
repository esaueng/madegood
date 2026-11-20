/// A fixed-distance paddling result on the selected track's replay clock. Values
/// stay in metres and seconds regardless of the display units.
public struct PaddlingSplit: Sendable, Hashable {
    public static let targetDistance = 1000.0

    /// 1-based, from the start of the selected track.
    public let index: Int
    /// The bounds for the replay cursor and timeline highlight.
    public let elapsedRange: ClosedRange<Double>
    /// Contributing intervals on the same clock. Clip the route to each range
    /// separately to leave pauses and GPS outages out of the highlighted route.
    public let movingRanges: [ClosedRange<Double>]
    public let movingTime: Double
    public let distance: Double
    public let isComplete: Bool

    /// Distance over moving time, m/s, using the same definition as a workout lap.
    public var averageSpeed: Double { distance / movingTime }

    static func makeSplits(from intervals: [SessionEngine.MovementInterval]) -> [Self] {
        // Match the workout auto-lap tolerance for summed great-circle steps.
        let distanceTolerance = 1e-6
        var splits: [Self] = []
        var ranges: [ClosedRange<Double>] = []
        var distance = 0.0

        func record(from start: Double, to end: Double) {
            guard start < end else { return }
            if let last = ranges.last, last.upperBound == start {
                ranges[ranges.count - 1] = last.lowerBound...end
            } else {
                ranges.append(start...end)
            }
        }

        func finish(distance: Double, isComplete: Bool) {
            guard let first = ranges.first, let last = ranges.last else { return }
            splits.append(
                Self(
                    index: splits.count + 1, elapsedRange: first.lowerBound...last.upperBound,
                    movingRanges: ranges, movingTime: ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) },
                    distance: distance, isComplete: isComplete))
            ranges = []
        }

        for interval in intervals {
            var start = interval.elapsedRange.lowerBound
            let end = interval.elapsedRange.upperBound
            var remaining = interval.distance
            if remaining > 0, distance + remaining >= targetDistance - distanceTolerance {
                // Each observed step is shorter than a split under the GPS filter.
                // Locate the crossing on the same linear distance model as the replay.
                let fraction = min(1, (targetDistance - distance) / remaining)
                let boundary = fraction == 1 ? end : start + (end - start) * fraction
                record(from: start, to: boundary)
                finish(distance: targetDistance, isComplete: true)
                distance = 0
                remaining *= 1 - fraction
                start = boundary
            }
            if start < end {
                record(from: start, to: end)
                distance += remaining
            }
        }
        if distance > distanceTolerance {
            finish(distance: distance, isComplete: false)
        }
        return splits
    }
}
