import Foundation

/// One contiguous range to keep, measured in seconds on the original recording's timeline.
/// Both endpoints are included. A trim is always applied to the original recording.
public struct SessionTrim: Sendable, Hashable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidBounds
        case exceedsRecording(availableEnd: Double)
    }

    public let range: ClosedRange<Double>

    public init(start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw Error.invalidBounds }
        range = start...end
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

    fileprivate func select(from session: RawSession) throws -> (track: Track, gpsTimes: [Double]) {
        try validate(in: session)
        let start = range.lowerBound
        let end = range.upperBound
        let retainedGPS = session.gps.filter { range.contains($0.t) }
        let gps = retainedGPS.map { fix in
            var selected = fix
            selected.t -= start
            return selected
        }
        let hr = session.hr.compactMap { sample -> HRSample? in
            guard range.contains(sample.t) else { return nil }
            return HRSample(t: sample.t - start, bpm: sample.bpm)
        }

        // RawSession is sorted and retains source order at equal timestamps.
        let userEvents = session.events.filter { $0.t.isFinite && $0.data?["auto"] != .bool(true) }
        var events = [SessionEvent(t: 0, type: .start)]
        let lastPauseChange = userEvents.last {
            $0.t < start && ($0.type == .pause || $0.type == .resume)
        }
        let changesPauseAtStart = userEvents.contains {
            $0.t == start && ($0.type == .pause || $0.type == .resume)
        }
        // A transition at the boundary sets the initial state itself. In particular,
        // carrying a pause into an immediate resume would discard the first moving step.
        if lastPauseChange?.type == .pause && !changesPauseAtStart {
            events.append(SessionEvent(t: 0, type: .pause))
        }
        events += userEvents.compactMap { event -> SessionEvent? in
            guard range.contains(event.t), event.type != .start, event.type != .stop else { return nil }
            return SessionEvent(t: event.t - start, type: event.type, data: event.data)
        }
        // Replay processes sensor readings before events at equal times, and this stop
        // follows any retained marks/laps at the endpoint. It also closes a quiet tail.
        events.append(SessionEvent(t: end - start, type: .stop))
        let track = Track(
            sessionId: session.meta.sessionId, sport: session.meta.sport,
            startedAt: session.startedAt.addingTimeInterval(start), gps: gps, hr: hr, events: events)
        return (track, retainedGPS.map(\.t))
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

    /// Original times in selected GPS index order. Adding the trim offset to a
    /// Date and then adding the rebased fix time can round across a GPX millisecond.
    struct OriginalGPSClock: Sendable {
        let startedAt: Date
        let times: [Double]
    }
    let originalGPSClock: OriginalGPSClock?

    /// A trim uses only the selected sensor readings and the manual pause state at its
    /// start. Auto-pause and auto-laps are recomputed with the supplied sport profile.
    /// A positive range may contain sparse or zero samples, in which case elapsed still
    /// covers the range and distance/moving time need observed intervals to accumulate.
    ///
    /// Keep this track local. Persist the original-timeline bounds separately from
    /// the raw recording and track v1. Removing the bounds restores the original.
    public init(session: RawSession, trim: SessionTrim? = nil, profile: SportProfile? = nil) throws {
        if let trim {
            let selected = try trim.select(from: session)
            let replay = SessionReplay(track: selected.track, profile: profile)
            self.replay = replay
            track = replay.analyzedTrack(from: selected.track)
            duration = replay.metrics.elapsed
            originalGPSClock = OriginalGPSClock(startedAt: session.startedAt, times: selected.gpsTimes)
        } else {
            track = session.track()
            replay = SessionReplay(track: track, profile: profile)
            duration = max(replay.metrics.elapsed, SessionTrim.availableEnd(in: session))
            originalGPSClock = nil
        }
    }
}
