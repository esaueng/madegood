/// Five effort zones shared by all sports, based on a configured maximum heart rate.
public struct HeartRateZones: Hashable, Sendable {
    public enum Zone: Int, CaseIterable, Sendable {
        case one = 1, two, three, four, five
    }

    /// A fallback for users who have not entered their own maximum.
    public static let defaultMaximum = 190
    public static let maximumRange = 60...250
    /// The inclusive lower bounds of zones 2 through 5, in percent of maximum.
    public static let defaultThresholds = [60, 70, 80, 90]
    public static let thresholdRange = 1...100
    /// At the typical 1–5 s sample cadence, anything longer is treated as a gap.
    public static let maximumSampleGap: Double = 15

    public let maximum: Int
    public let thresholds: [Int]

    public init(maximum: Int = Self.defaultMaximum, thresholds: [Int] = Self.defaultThresholds) {
        self.maximum = Self.maximumRange.contains(maximum) ? maximum : Self.defaultMaximum
        self.thresholds = Self.validThresholds(thresholds) ? thresholds : Self.defaultThresholds
    }

    private static func validThresholds(_ thresholds: [Int]) -> Bool {
        thresholds.count == 4 && thresholds.allSatisfy(thresholdRange.contains)
            && zip(thresholds, thresholds.dropFirst()).allSatisfy(<)
    }

    public func zone(for bpm: Double) -> Zone? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        // Compare against each boundary in bpm to avoid rounding the sample's percentage.
        let higherZones = thresholds.prefix { bpm >= Double($0 * maximum) / 100 }.count
        return Zone(rawValue: higherZones + 1)
    }

    /// Seconds in each zone, using the selected replay's manual and regenerated auto
    /// pauses and its retained ranges. Each sample represents the following interval
    /// while active, provided another valid sample confirms it within the gap limit.
    public func durations(in selection: SessionSelection) -> [Zone: Double] {
        durations(samples: selection.track.hr, events: selection.replay.events, spans: selection.replayRanges)
    }

    func durations(
        samples: [HRSample], events: [SessionEvent], spans: [ClosedRange<Double>]
    ) -> [Zone: Double] {
        let transitions = events.filter {
            $0.t.isFinite && ($0.type == .pause || $0.type == .resume || $0.type == .stop)
        }.sorted { $0.t < $1.t }
        let stop = transitions.first { $0.type == .stop }?.t ?? .infinity
        let samples = samples.filter { $0.t.isFinite && $0.t >= 0 && $0.t <= stop }.sorted { $0.t < $1.t }
        var totals: [Zone: Double] = [:]
        var sampleIndex = 0
        var eventIndex = 0
        for span in spans {
            while sampleIndex < samples.count, samples[sampleIndex].t < span.lowerBound { sampleIndex += 1 }
            while eventIndex < transitions.count, transitions[eventIndex].t < span.lowerBound { eventIndex += 1 }
            // Replay resets its engine at a cut and emits a pause at this boundary if the
            // original recording was already manually paused when the retained span began.
            var paused = false
            var previous: (time: Double, zone: Zone)?
            while sampleIndex < samples.count, samples[sampleIndex].t <= span.upperBound {
                let sample = samples[sampleIndex]
                sampleIndex += 1
                var intervalEnd = sample.t
                while eventIndex < transitions.count, transitions[eventIndex].t <= sample.t {
                    let event = transitions[eventIndex]
                    eventIndex += 1
                    if event.type == .pause || event.type == .stop {
                        intervalEnd = min(intervalEnd, event.t)
                    }
                    paused = event.type != .resume
                }
                let currentZone = zone(for: sample.bpm)
                if let previous, currentZone != nil, sample.t - previous.time <= Self.maximumSampleGap,
                    intervalEnd > previous.time
                {
                    totals[previous.zone, default: 0] += intervalEnd - previous.time
                }
                previous = paused ? nil : currentZone.map { (sample.t, $0) }
            }
        }
        return totals
    }
}
