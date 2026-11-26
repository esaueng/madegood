/// Runs a recorded track back through the live engine, for history and session detail.
/// The result matches what the device showed live, given the same samples and profile.
public struct SessionReplay: Sendable {
    public var metrics: LiveMetrics
    /// The fixes the engine accepted, in time order (for maps and speed charts).
    public var fixes: [GPSFix]
    /// The user's events plus the engine's regenerated auto-pause, auto-resume and
    /// auto-lap events, in time order.
    public var events: [SessionEvent]
    /// Post-session fixed-distance splits for kayak, canoe and SUP. Workout laps
    /// are in `metrics.laps` and `metrics.currentLap`.
    public let paddlingSplits: [PaddlingSplit]
    /// Observed moving steps for paddling analyses, excluding replay route gaps.
    let paddlingMovement: [SessionEngine.MovementInterval]
    let windsurfPlaning: WindsurfAnalysis.Planing?
    /// Vehicle legs the engine left out (docs/metrics.md "Transport"), on the replay clock.
    public let transportIntervals: [ClosedRange<Double>]
    /// Auto-pauses and vehicle legs on the replay clock, merged and in time order: each
    /// auto-pause runs to the next resume, manual pause or stop, or a removed interval; one
    /// still open at the end has no upper bound (+infinity). Manual pauses are left out: stroke detection already applies them on
    /// the motion sensor's clock (docs/metrics.md "Strokes").
    public let autoPausedIntervals: [ClosedRange<Double>]

    /// Open intervals on the replay clock whose samples were removed by a local edit.
    /// Both boundary instants of each interval are retained.
    public let removedIntervals: [ClosedRange<Double>]

    /// Accepted fixes in each retained span, in order. A span may be empty.
    public var fixSpans: [ArraySlice<GPSFix>] {
        var start = fixes.startIndex
        var spans: [ArraySlice<GPSFix>] = []
        for interval in removedIntervals {
            let split = fixes[start...].firstIndex { $0.t >= interval.upperBound } ?? fixes.endIndex
            spans.append(fixes[start..<split])
            start = split
        }
        spans.append(fixes[start...])
        return spans
    }

    public init(track: Track, profile: SportProfile? = nil) {
        self.init(track: track, profile: profile, removedIntervals: [])
    }

    init(track: Track, profile: SportProfile?, removedIntervals: [ClosedRange<Double>]) {
        self.removedIntervals = removedIntervals
        var profile = profile ?? .standard(for: track.sport)
        // After the session, `SessionSelection.sailingAnalysis` analyzes sailing in one
        // pass; the live tracker's periodic refreshes are not needed here.
        profile.tracksSailing = false
        var engine = SessionEngine(
            profile: profile, recordsMovement: track.sport.isPaddling || track.sport == .windsurfing)
        // Events the engine generated live are stored with {"auto": true}. They are left
        // out here and regenerated; fed back in, an auto-pause would act as a manual one.
        let userEvents = track.events.filter { $0.data?["auto"] != .bool(true) }
        // At equal times: fixes, then heart rate, then events, so a stop at the time of
        // the last fix still counts that fix.
        var samples: [(t: Double, order: Int, sample: Sample)] = []
        samples += track.gps.map { ($0.t, 0, .gps($0)) }
        samples += track.hr.map { ($0.t, 1, .hr($0)) }
        samples += userEvents.map { ($0.t, 2, .event($0)) }
        samples.sort { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }

        var fixes: [GPSFix] = []
        var nextSpan = 0
        for (time, _, sample) in samples {
            while nextSpan < removedIntervals.count, time >= removedIntervals[nextSpan].upperBound {
                engine.skipRemovedInterval(removedIntervals[nextSpan])
                nextSpan += 1
            }
            let accepted = engine.snapshot.acceptedFixes
            engine.ingest(sample)
            if case .gps(let fix) = sample, engine.snapshot.acceptedFixes > accepted { fixes.append(fix) }
        }
        metrics = engine.snapshot
        self.fixes = fixes
        events = (userEvents + engine.generatedEvents).sorted { $0.t < $1.t }
        transportIntervals = engine.transportIntervals
        autoPausedIntervals = Self.autoPausedIntervals(
            events: events, transport: engine.transportIntervals, removed: removedIntervals, end: .infinity)
        let intervals = engine.movementIntervals ?? []
        let movement = intervals.filter { $0.duration <= SessionReplayTimeline.maxRouteGap }
        paddlingMovement = track.sport.isPaddling ? movement : []
        paddlingSplits = track.sport.isPaddling ? PaddlingSplit.makeSplits(from: movement) : []
        windsurfPlaning =
            track.sport == .windsurfing
            ? WindsurfAnalysis.Planing(fixes: fixes, intervals: intervals, threshold: profile.planingSpeedThreshold)
            : nil
    }

    static func autoPausedIntervals(
        events: [SessionEvent], transport: [ClosedRange<Double>], removed: [ClosedRange<Double>], end: Double
    ) -> [ClosedRange<Double>] {
        var intervals = transport
        var pausedSince: Double?
        var nextCut = 0
        for event in events where event.type == .pause || event.type == .resume || event.type == .stop {
            // The engine starts each retained span moving.
            while nextCut < removed.count, event.t >= removed[nextCut].upperBound {
                if let since = pausedSince { intervals.append(since...max(since, removed[nextCut].lowerBound)) }
                pausedSince = nil
                nextCut += 1
            }
            switch event.type {
            case .pause where event.data?["auto"] == .bool(true):
                if pausedSince == nil { pausedSince = event.t }
            default:
                if let since = pausedSince { intervals.append(since...max(since, event.t)) }
                pausedSince = nil
            }
        }
        if let since = pausedSince { intervals.append(since...max(since, end)) }
        var merged: [ClosedRange<Double>] = []
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Version of the analysis that produced `summary` and the generated events. Bump it
    /// when a metric definition in docs/metrics.md changes, so stored tracks can be
    /// re-analyzed.
    public static let analyzerVersion = "1.3.0"

    /// The session summary stored in track v1 (`summary`, docs/metrics.md "Session
    /// summary"). Values are SI; absent values are left out.
    public var summary: JSONValue {
        var fields: [String: JSONValue] = [
            "distance": .number(metrics.distance),
            "movingTime": .number(metrics.movingTime),
            "elapsed": .number(metrics.elapsed),
            "laps": .array(
                (metrics.laps + (metrics.laps.isEmpty ? [] : [metrics.currentLap])).map { lap in
                    .object([
                        "start": .number(lap.start), "end": .number(lap.end), "distance": .number(lap.distance),
                        "movingTime": .number(lap.movingTime), "auto": .bool(lap.isAuto),
                    ])
                }),
        ]
        let optional: [(String, Double?)] = [
            ("averageSpeed", metrics.averageSpeed), ("maxSpeed2s", metrics.maxSpeed2s),
            ("maxSpeed10s", metrics.maxSpeed10s), ("heartRateAverage", metrics.heartRateAverage),
            ("heartRateMax", metrics.heartRateMax),
        ]
        for (key, value) in optional {
            if let value, value.isFinite { fields[key] = .number(value) }
        }
        // Windsurfing only; the 2 s and 10 s categories are maxSpeed2s and maxSpeed10s.
        for (key, value) in metrics.speedCategories?.summaryFields ?? [:] { fields[key] = .number(value) }
        return .object(fields)
    }

    /// The track as stored and uploaded: the recorded GPS and heart rate, the user's and
    /// regenerated events, and this summary with `analyzerVersion`.
    public func analyzedTrack(from track: Track) -> Track {
        var analyzed = track
        analyzed.events = events
        analyzed.summary = summary
        analyzed.analyzerVersion = Self.analyzerVersion
        return analyzed
    }
}
