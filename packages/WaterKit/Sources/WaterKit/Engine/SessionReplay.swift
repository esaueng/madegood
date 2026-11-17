/// Runs a recorded track back through the live engine, for history and session detail.
/// The result matches what the device showed live, given the same samples and profile.
public struct SessionReplay: Sendable {
    public var metrics: LiveMetrics
    /// The fixes the engine accepted, in time order (for maps and speed charts).
    public var fixes: [GPSFix]
    /// The user's events plus the engine's regenerated auto-pause, auto-resume and
    /// auto-lap events, in time order.
    public var events: [SessionEvent]

    public init(track: Track, profile: SportProfile? = nil) {
        var engine = SessionEngine(profile: profile ?? .standard(for: track.sport))
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
        for (_, _, sample) in samples {
            let accepted = engine.snapshot.acceptedFixes
            engine.ingest(sample)
            if case .gps(let fix) = sample, engine.snapshot.acceptedFixes > accepted { fixes.append(fix) }
        }
        metrics = engine.snapshot
        self.fixes = fixes
        events = (userEvents + engine.generatedEvents).sorted { $0.t < $1.t }
    }
}
