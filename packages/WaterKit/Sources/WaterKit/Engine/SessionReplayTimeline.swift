/// Geometry and Doppler speed for an elapsed-time cursor over accepted fixes.
/// Route distance follows the displayed line, including fixes recorded during pauses.
/// The session summary continues to use the engine's moving-distance accounting.
public struct SessionReplayTimeline: Sendable {
    public struct Position: Sendable {
        public let latitude: Double
        public let longitude: Double
    }

    public struct Point: Sendable {
        public let elapsed: Double
        public let position: Position
        public let speed: Double?
        public let routeDistance: Double
        public let routeSegment: Int
    }

    public struct Selection: Sendable {
        public let elapsed: Double
        /// Absent outside the track or in a GPS gap.
        public let position: Position?
        /// Absent without a Doppler reading or readings bracketing the selection.
        public let speed: Double?
        public let routeDistance: Double
    }

    public let points: [Point]
    public let start: Double
    public let duration: Double
    private let speedProfile: SpeedProfile

    public init(replay: SessionReplay, recordedFixes: [GPSFix], endTime: Double? = nil) {
        start = min(0, replay.fixes.first?.t ?? 0)
        duration = max(replay.metrics.elapsed, endTime ?? 0)
        speedProfile = SpeedProfile(replay.fixes.filter { ($0.speed ?? -1) >= 0 })
        // SessionReplay retains the accepted fixes but drops the anchor flags. Recover
        // those flags with the same filter, including recovery after consecutive rejects.
        var filter = GPSFilter()
        var anchors: Set<Double> = []
        for fix in recordedFixes.filter({ $0.t.isFinite }).sorted(by: { $0.t < $1.t }) {
            if case .accepted(let accepted) = filter.ingest(fix), accepted.isAnchor {
                anchors.insert(fix.t)
            }
        }

        var points: [Point] = []
        for fix in replay.fixes {
            let position = Position(latitude: fix.latitude, longitude: fix.longitude)
            var segment = points.last?.routeSegment ?? 0
            var distance = points.last?.routeDistance ?? 0
            if let previous = points.last {
                // A chart cursor should stop tracing the route over a recording
                // outage even if the engine can still accept the next fix.
                if anchors.contains(fix.t) || fix.t - previous.elapsed > 5 {
                    segment += 1
                } else {
                    distance += Geo.distance(
                        lat1: previous.position.latitude, lon1: previous.position.longitude,
                        lat2: position.latitude, lon2: position.longitude)
                }
            }
            let speed = fix.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            points.append(
                Point(elapsed: fix.t, position: position, speed: speed, routeDistance: distance, routeSegment: segment))
        }
        self.points = points
    }

    /// A performance window follows the Doppler model used to compute its average.
    /// A route outage still has no interpolated position.
    public func speedCurve(in window: ClosedRange<Double>) -> [(elapsed: Double, speed: Double)] {
        let gap = window.upperBound - window.lowerBound
        guard let first = speedProfile.interpolatedValue(at: window.lowerBound, maxGap: gap),
            let last = speedProfile.interpolatedValue(at: window.upperBound, maxGap: gap),
            speedProfile.integral(from: window.lowerBound, to: window.upperBound, maxGap: gap) != nil
        else { return [] }
        let interior = zip(speedProfile.t, speedProfile.v).filter {
            $0.0 > window.lowerBound && $0.0 < window.upperBound
        }
        return [(window.lowerBound, first)] + interior + [(window.upperBound, last)]
    }

    public func selection(at elapsed: Double, speedWindow: ClosedRange<Double>? = nil) -> Selection {
        let time = elapsed.isFinite ? min(max(start, elapsed), duration) : 0
        let windowSpeed = speedWindow.flatMap { window in
            window.contains(time)
                ? speedProfile.interpolatedValue(at: time, maxGap: window.upperBound - window.lowerBound) : nil
        }
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].elapsed < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < points.count, points[low].elapsed == time {
            let point = points[low]
            return Selection(
                elapsed: time, position: point.position, speed: windowSpeed ?? point.speed,
                routeDistance: point.routeDistance)
        }
        let distance = low > 0 ? points[low - 1].routeDistance : 0
        guard low > 0, low < points.count, points[low - 1].routeSegment == points[low].routeSegment else {
            return Selection(elapsed: time, position: nil, speed: windowSpeed, routeDistance: distance)
        }

        let left = points[low - 1]
        let right = points[low]
        let fraction = (time - left.elapsed) / (right.elapsed - left.elapsed)
        let step = (right.routeDistance - left.routeDistance) * fraction
        let position: Position
        if step > 0 {
            let bearing = Geo.bearing(
                lat1: left.position.latitude, lon1: left.position.longitude,
                lat2: right.position.latitude, lon2: right.position.longitude)
            let (latitude, longitude) = Geo.destination(
                lat: left.position.latitude, lon: left.position.longitude, bearing: bearing, distance: step)
            position = Position(latitude: latitude, longitude: longitude)
        } else {
            position = left.position
        }
        let speed: Double?
        if let first = left.speed, let second = right.speed {
            speed = first + (second - first) * fraction
        } else {
            speed = nil
        }
        return Selection(elapsed: time, position: position, speed: windowSpeed ?? speed, routeDistance: distance + step)
    }
}
