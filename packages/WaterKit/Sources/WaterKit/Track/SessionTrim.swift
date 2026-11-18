import Foundation

/// Disjoint ranges to keep on the original recording clock. Each retained range
/// includes both endpoints.
public struct SessionTrim: Sendable, Hashable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidBounds
        case invalidRemoval
        case exceedsRecording(availableEnd: Double)
    }

    public let retainedRanges: [ClosedRange<Double>]
    public var range: ClosedRange<Double> {
        retainedRanges[0].lowerBound...retainedRanges[retainedRanges.count - 1].upperBound
    }
    public var removedRanges: [ClosedRange<Double>] {
        zip(retainedRanges, retainedRanges.dropFirst()).map { $0.upperBound...$1.lowerBound }
    }

    public init(start: Double, end: Double) throws {
        try self.init(start: start, end: end, removing: [])
    }

    public init(start: Double, end: Double, removing cuts: [ClosedRange<Double>]) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw Error.invalidBounds }
        var spans: [ClosedRange<Double>] = []
        var lower = start
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard lower < cut.lowerBound, cut.lowerBound < cut.upperBound, cut.upperBound < end
            else { throw Error.invalidRemoval }
            spans.append(lower...cut.lowerBound)
            lower = cut.upperBound
        }
        spans.append(lower...end)
        retainedRanges = spans
    }

    public init(retaining spans: [ClosedRange<Double>]) throws {
        guard !spans.isEmpty,
            spans.allSatisfy({
                $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= 0 && $0.lowerBound < $0.upperBound
            })
        else { throw Error.invalidBounds }
        guard zip(spans, spans.dropFirst()).allSatisfy({ $0.upperBound < $1.lowerBound }) else {
            throw Error.invalidRemoval
        }
        retainedRanges = spans
    }

    /// The upper bound the editor can offer. A clean end or a recorded stop caps the
    /// selection. Otherwise the last GPS, heart-rate or event time is the available end.
    /// The result is the same when the raw reader skips the motion stream.
    public static func availableEnd(in session: RawSession) -> Double {
        let stop = session.events.first {
            $0.type == .stop && $0.data?["auto"] != .bool(true) && $0.t.isFinite && $0.t >= 0
        }?.t
        let end = session.meta.endedAt.map { $0 - session.meta.startedAt }
        if let end, end.isFinite, end >= 0 { return min(end, stop ?? end) }
        if let stop { return stop }
        return max(
            0, session.gps.last(where: { $0.t.isFinite })?.t ?? 0,
            session.hr.last(where: { $0.t.isFinite })?.t ?? 0,
            session.events.last(where: { $0.t.isFinite })?.t ?? 0)
    }

    func validate(in session: RawSession) throws {
        let availableEnd = Self.availableEnd(in: session)
        guard range.upperBound <= availableEnd else { throw Error.exceedsRecording(availableEnd: availableEnd) }
    }

    fileprivate var replayRanges: [ClosedRange<Double>] {
        let start = range.lowerBound
        var ranges: [ClosedRange<Double>] = []
        for span in retainedRanges {
            // Subtracting the origin can round both sides of a very short cut to
            // the same instant. Advance the next span by the minimum representable step.
            let lower = max(span.lowerBound - start, ranges.last?.upperBound.nextUp ?? 0)
            ranges.append(lower...max(lower, span.upperBound - start))
        }
        return ranges
    }

    fileprivate func select(
        from session: RawSession, replayRanges: [ClosedRange<Double>]
    ) throws -> (track: Track, gpsTimes: [Double]) {
        try validate(in: session)
        let start = range.lowerBound
        func selectedTime(_ time: Double) -> Double? {
            guard let index = retainedRanges.firstIndex(where: { $0.contains(time) }) else { return nil }
            return max(time - start, replayRanges[index].lowerBound)
        }
        var gpsTimes: [Double] = []
        let gps = session.gps.compactMap { fix -> GPSFix? in
            guard let time = selectedTime(fix.t) else { return nil }
            gpsTimes.append(fix.t)
            var selected = fix
            selected.t = time
            return selected
        }
        let hr = session.hr.compactMap { sample -> HRSample? in
            guard let time = selectedTime(sample.t) else { return nil }
            return HRSample(t: time, bpm: sample.bpm)
        }

        // RawSession is sorted and retains source order at equal timestamps.
        let userEvents = session.events.filter { $0.t.isFinite && $0.data?["auto"] != .bool(true) }
        var events = [SessionEvent(t: 0, type: .start)]
        for (span, replayRange) in zip(retainedRanges, replayRanges) {
            let lastPauseChange = userEvents.last {
                $0.t < span.lowerBound && ($0.type == .pause || $0.type == .resume)
            }
            let changesPauseAtStart = userEvents.contains {
                $0.t == span.lowerBound && ($0.type == .pause || $0.type == .resume)
            }
            // A transition at the boundary sets the initial state itself.
            if lastPauseChange?.type == .pause && !changesPauseAtStart {
                events.append(SessionEvent(t: replayRange.lowerBound, type: .pause))
            }
            events += userEvents.compactMap { event -> SessionEvent? in
                guard span.contains(event.t), event.type != .start, event.type != .stop else { return nil }
                return SessionEvent(t: max(event.t - start, replayRange.lowerBound), type: event.type, data: event.data)
            }
        }
        // Replay processes sensor readings before events at equal times, and this stop
        // follows any retained marks/laps at the endpoint. It also closes a quiet tail.
        events.append(SessionEvent(t: replayRanges[replayRanges.count - 1].upperBound, type: .stop))
        let track = Track(
            sessionId: session.meta.sessionId, sport: session.meta.sport,
            startedAt: session.startedAt.addingTimeInterval(start), gps: gps, hr: hr, events: events)
        return (track, gpsTimes)
    }
}

/// The local presentation of a saved recording. Pass the same selection to detail, GPX
/// and History. With no trim, the track and replay use the original recording behavior.
public struct SessionSelection: Sendable {
    /// Selected GPS, heart rate and events, on the same clock as the replay. The trimmed
    /// track includes the regenerated analysis events used by GPX to split on resume.
    public let track: Track
    public let replay: SessionReplay
    /// The display clock includes a known quiet tail even without a stop event.
    public let duration: Double
    /// The original-clock instant displayed as zero in replay.
    public let sourceStart: Double
    /// Inclusive retained ranges on the original recording clock.
    public let retainedRanges: [ClosedRange<Double>]
    /// The same ranges on the replay clock, preserving elapsed time between their boundaries.
    public let replayRanges: [ClosedRange<Double>]
    /// Total selected time, excluding the interior interval visible as a gap on the replay clock.
    public var retainedDuration: Double {
        guard !replay.removedIntervals.isEmpty else { return duration }
        return retainedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public func replayTime(forSourceTime time: Double) -> Double {
        let rebased = time - sourceStart
        guard let index = retainedRanges.firstIndex(where: { $0.contains(time) }) else { return rebased }
        return max(rebased, replayRanges[index].lowerBound)
    }

    public func sourceTime(forReplayTime time: Double) -> Double {
        let original = time + sourceStart
        guard let index = replayRanges.firstIndex(where: { $0.contains(time) }) else { return original }
        let span = retainedRanges[index]
        return min(max(original, span.lowerBound), span.upperBound)
    }

    /// Original times in selected GPS index order. Adding the trim offset to a
    /// Date and then adding the rebased fix time can round across a GPX millisecond.
    struct OriginalGPSClock: Sendable {
        let startedAt: Date
        let times: [Double]
    }
    let originalGPSClock: OriginalGPSClock?

    /// A trim uses only the selected sensor readings and the manual pause state at the
    /// start of each span. Auto-pause and auto-laps are recomputed with the sport profile.
    /// A positive range may contain sparse or zero samples, in which case elapsed still
    /// covers the range and distance/moving time need observed intervals to accumulate.
    ///
    /// Keep this track local. Persist the original-timeline bounds separately from
    /// the raw recording and track v1. Removing the bounds restores the original.
    public init(session: RawSession, trim: SessionTrim? = nil, profile: SportProfile? = nil) throws {
        if let trim {
            let ranges = trim.replayRanges
            let selected = try trim.select(from: session, replayRanges: ranges)
            let origin = trim.range.lowerBound
            let removedIntervals = zip(ranges, ranges.dropFirst()).map { $0.upperBound...$1.lowerBound }
            let replay = SessionReplay(track: selected.track, profile: profile, removedIntervals: removedIntervals)
            self.replay = replay
            track = replay.analyzedTrack(from: selected.track)
            duration = replay.metrics.elapsed
            sourceStart = origin
            retainedRanges = trim.retainedRanges
            replayRanges = ranges
            originalGPSClock = OriginalGPSClock(startedAt: session.startedAt, times: selected.gpsTimes)
        } else {
            track = session.track()
            replay = SessionReplay(track: track, profile: profile)
            duration = max(replay.metrics.elapsed, SessionTrim.availableEnd(in: session))
            sourceStart = 0
            retainedRanges = [min(0, replay.fixes.first?.t ?? 0)...duration]
            replayRanges = retainedRanges
            originalGPSClock = nil
        }
    }
}
