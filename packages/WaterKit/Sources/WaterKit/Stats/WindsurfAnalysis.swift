/// Post-session planing and estimated gybes for a windsurfing selection.
public struct WindsurfAnalysis: Sendable, Hashable {
    public struct Planing: Sendable, Hashable {
        /// Seconds in sustained runs above the planing threshold.
        public let time: Double
        /// Active seconds with enough Doppler data to measure planing.
        public let observedTime: Double
        public var fraction: Double { time / observedTime }

        init?(fixes: [GPSFix], intervals: [SessionEngine.MovementInterval], threshold: Double) {
            guard threshold.isFinite, threshold > 0 else { return nil }
            var observed = 0.0
            var total = 0.0
            var run = 0.0
            var movement = intervals.makeIterator()
            var interval = movement.next()

            func finishRun() {
                if run >= 3 { total += run }
                run = 0
            }

            for (a, b) in zip(fixes, fixes.dropFirst()) {
                while let current = interval, current.elapsedRange.upperBound < b.t {
                    interval = movement.next()
                }
                let dt = b.t - a.t
                // An accounted interval excludes pauses, anchor jumps and trim cuts.
                guard dt > 0, dt <= 5, interval?.elapsedRange == a.t...b.t,
                    let first = a.speed, let last = b.speed,
                    first.isFinite, last.isFinite, first >= 0, last >= 0
                else {
                    finishRun()
                    continue
                }
                observed += dt
                let above = max(first, last)
                guard above > threshold else {
                    finishRun()
                    continue
                }
                if first <= threshold { finishRun() }
                // Linear interpolation locates the crossing inside the sample interval.
                let below = min(first, last)
                run += below >= threshold ? dt : dt * (above - threshold) / (above - below)
                if last <= threshold { finishRun() }
            }
            finishRun()
            guard observed > 0 else { return nil }
            time = total
            observedTime = observed
        }
    }

    /// Nil without a usable Doppler interval.
    public let planing: Planing?
    /// Nil when the course evidence cannot establish an axis or finds turns around both directions.
    public let estimatedGybeCount: Int?
}

extension SessionSelection {
    public func windsurfAnalysis() -> WindsurfAnalysis? {
        guard track.sport == .windsurfing else { return nil }
        let runs = sailingObservationRuns()
        let histogram = Self.courseHistogram(runs, minimumSpeed: 3)
        var count: Int?
        if let axis = histogram.windEstimate(legAngles: 65...170),
            histogram.legTime(axis) >= histogram.totalTime / 2
        {
            // Either end of the axis could be downwind. A gybe from above beam may
            // follow the longer arc (>180°). Require the turns to favor a single end.
            let turns = SailingManeuverDetector.detect(in: runs, windFrom: axis.fromDegrees, maximumTurnAngle: 240)
            let towardOpposite = turns.count { $0.event.type == .gybe }
            if towardOpposite == 0 || towardOpposite == turns.count { count = turns.count }
        }
        return WindsurfAnalysis(planing: replay.windsurfPlaning, estimatedGybeCount: count)
    }
}
