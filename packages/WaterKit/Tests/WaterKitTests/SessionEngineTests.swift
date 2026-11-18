import Foundation
import Testing

@testable import WaterKit

/// Builds 1 Hz fixes heading east from (0, 0). The position at t is the distance covered
/// at the speed of each earlier whole second, so position steps and Doppler speeds agree.
private struct Run {
    var speed: @Sendable (Double) -> Double
    var course: @Sendable (Double) -> Double = { _ in 90 }
    var hacc: @Sendable (Double) -> Double = { _ in 5 }

    func along(_ t: Double) -> Double {
        stride(from: 0.0, to: t, by: 1).reduce(0) { $0 + speed($1) }
    }

    func fix(_ t: Double, offset: Double = 0) -> GPSFix {
        let point = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: along(t) + offset)
        return GPSFix(
            t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: hacc(t), speed: speed(t),
            course: course(t))
    }

    func fixes(_ range: ClosedRange<Int>) -> [GPSFix] { range.map { fix(Double($0)) } }
}

private func simulate(_ sport: Sport, _ samples: [Sample], profile: SportProfile? = nil) -> SessionEngine {
    var engine = profile.map { SessionEngine(profile: $0) } ?? SessionEngine(sport: sport)
    for sample in samples.sorted(by: { $0.t < $1.t }) { engine.ingest(sample) }
    return engine
}

private func approx(_ a: Double?, _ b: Double, tolerance: Double = 0.01) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance * max(1, abs(b))
}

@Suite struct SessionEngineTests {
    @Test func steadyPaddle() {
        let fixes = Run(speed: { _ in 2 }).fixes(0...99)
        let m = simulate(.kayak, fixes.map(Sample.gps)).snapshot
        #expect(approx(m.distance, 198))
        #expect(m.movingTime == 99)
        #expect(m.elapsed == 99)
        #expect(approx(m.averageSpeed, 2))
        #expect(approx(m.speed, 2))
        #expect(approx(m.maxSpeed2s, 2))
        #expect(approx(m.maxSpeed10s, 2))
        #expect(approx(m.course, 90))
        #expect(m.pauseState == .moving)
        #expect(m.acceptedFixes == 100 && m.rejectedFixes == 0)
    }

    /// 60 s at 1.5 m/s, 40 s stopped, 60 s at 1.5 m/s.
    private static var stopAndGo: Run { Run(speed: { t in t < 60 || t >= 100 ? 1.5 : 0 }) }

    @Test func autoPauseDatesBackAndResumes() {
        let engine = simulate(.kayak, Self.stopAndGo.fixes(0...159).map(Sample.gps))
        let m = engine.snapshot
        // Paused from the first stopped fix (t = 60); resumed from the start of the
        // interval in which the boat got going again (t = 99).
        #expect(engine.generatedEvents.map(\.type) == [.pause, .resume])
        #expect(engine.generatedEvents.map(\.t) == [60, 99])
        #expect(m.movingTime == 60 + 60)
        #expect(approx(m.distance, 1.5 * 60 + 1.5 * 59))
        #expect(m.pauseState == .moving)
        #expect(m.elapsed == 159)
    }

    @Test func autoPauseIsOffForSailing() {
        let engine = simulate(.sailing, Self.stopAndGo.fixes(0...159).map(Sample.gps))
        #expect(engine.generatedEvents.isEmpty)
        #expect(engine.snapshot.movingTime == 159)
    }

    @Test func briefSlowdownDoesNotPause() {
        let run = Run(speed: { t in (30..<38).contains(t) ? 0.2 : 1.5 })
        let engine = simulate(.kayak, run.fixes(0...99).map(Sample.gps))
        #expect(engine.generatedEvents.isEmpty)
        #expect(engine.snapshot.movingTime == 99)
    }

    @Test func staysPausedWhileDrifting() {
        // Drifting at 0.6 m/s sits between the pause and resume thresholds.
        let run = Run(speed: { t in t < 30 ? 1.5 : (t < 50 ? 0 : 0.6) })
        let engine = simulate(.kayak, run.fixes(0...99).map(Sample.gps))
        #expect(engine.generatedEvents.map(\.type) == [.pause])
        #expect(engine.snapshot.pauseState == .autoPaused)
        #expect(engine.snapshot.movingTime == 30)
    }

    @Test func manualPauseExcludesTime() {
        let fixes = Run(speed: { _ in 2 }).fixes(0...99)
        let samples =
            fixes.map(Sample.gps) + [
                .event(SessionEvent(t: 40.5, type: .pause)), .event(SessionEvent(t: 60.5, type: .resume)),
            ]
        let engine = simulate(.sailing, samples)
        // Intervals ending at fixes 41…60 fall in the pause; the one ending at 61 started
        // before the resume, so accounting restarts from fix 61.
        #expect(engine.snapshot.movingTime == 78)
        #expect(approx(engine.snapshot.distance, 156))
        #expect(engine.generatedEvents.isEmpty)
    }

    @Test func manualPauseOverridesAutoResume() {
        let samples =
            Self.stopAndGo.fixes(0...159).map(Sample.gps) + [.event(SessionEvent(t: 80.5, type: .pause))]
        let engine = simulate(.kayak, samples)
        #expect(engine.snapshot.pauseState == .manuallyPaused)
        #expect(engine.generatedEvents.map(\.type) == [.pause])
        #expect(engine.snapshot.movingTime == 60)
    }

    @Test func rejectsInaccurateFixes() {
        let run = Run(speed: { _ in 2 }, hacc: { t in t == 50 ? 40 : 5 })
        var fixes = run.fixes(0...99)
        fixes[60].horizontalAccuracy = nil
        let m = simulate(.kayak, fixes.map(Sample.gps)).snapshot
        #expect(m.rejectedFixes == 2)
        #expect(approx(m.distance, 198))
        #expect(m.movingTime == 99)
    }

    @Test func rejectsSingleJumpAndSpeedSpike() {
        let run = Run(speed: { _ in 2 })
        var fixes = run.fixes(0...99)
        fixes[30] = run.fix(30, offset: 500)
        fixes[70].speed = 20
        let m = simulate(.kayak, fixes.map(Sample.gps)).snapshot
        #expect(m.rejectedFixes == 2)
        #expect(approx(m.distance, 198))
        #expect(approx(m.maxSpeed2s, 2))
    }

    @Test func reanchorsAfterAPersistentShift() {
        // From t = 50 every fix is 2 km further east: a real relocation the filter must
        // eventually follow, without counting the 2 km as distance.
        let run = Run(speed: { _ in 2 })
        let fixes = (0...99).map { run.fix(Double($0), offset: $0 >= 50 ? 2_000 : 0) }
        let m = simulate(.kayak, fixes.map(Sample.gps)).snapshot
        let config = GPSFilter.Config()
        #expect(m.rejectedFixes == config.maxConsecutiveRejections)
        #expect(m.distance < 200)
        #expect(m.distance > 150)
    }

    @Test func courseSmoothingWrapsAroundNorth() {
        let run = Run(speed: { _ in 2 }, course: { t in Int(t) % 2 == 0 ? 358 : 2 })
        let m = simulate(.sailing, run.fixes(0...30).map(Sample.gps)).snapshot
        let course = m.course ?? 180
        #expect(min(course, 360 - course) < 3)
    }

    @Test func courseIgnoredWhenStopped() {
        let run = Run(speed: { t in t < 20 ? 2 : 0.1 }, course: { t in t < 20 ? 45 : 270 })
        let m = simulate(.sailing, run.fixes(0...40).map(Sample.gps)).snapshot
        #expect(approx(m.course, 45))
    }

    @Test func manualAndAutoLaps() {
        var profile = SportProfile.standard(for: .kayak)
        profile.autoLapDistance = 100
        let fixes = Run(speed: { _ in 2 }).fixes(0...130)
        let engine = simulate(
            .kayak, fixes.map(Sample.gps) + [.event(SessionEvent(t: 30, type: .lap))], profile: profile)
        let m = engine.snapshot
        #expect(m.laps.map(\.isAuto) == [false, true, true])
        #expect(m.laps.map(\.end) == [30, 80, 130])
        #expect(approx(m.laps[0].distance, 60))
        #expect(approx(m.laps[1].distance, 100))
        #expect(approx(m.laps[1].averageSpeed, 2))
        #expect(m.currentLap.index == 4)
        #expect(engine.generatedEvents.filter { $0.type == .lap }.map(\.t) == [80, 130])
    }

    @Test func liveMaxSpeedMatchesPostSessionStats() {
        // At 1 Hz the causal and offline candidate windows coincide (docs/metrics.md).
        let run = Run(speed: { t in (40..<46).contains(t) ? 4.5 : (t < 70 ? 1.8 : 2.4) })
        let fixes = run.fixes(0...119)
        let m = simulate(.windsurfing, fixes.map(Sample.gps)).snapshot
        #expect(approx(m.maxSpeed2s, SessionStats.bestAverageSpeed(fixes, window: 2)!, tolerance: 1e-9))
        #expect(approx(m.maxSpeed10s, SessionStats.bestAverageSpeed(fixes, window: 10)!, tolerance: 1e-9))
    }

    @Test func maxSpeedWindowsKeepTheEarliestExactTie() {
        // This run outlasts the recent speed buffer. The original winners remain available.
        let fixes = Run(speed: { _ in 2 }).fixes(0...60)
        let m = simulate(.sailing, fixes.map(Sample.gps)).snapshot
        #expect(m.maxSpeed2s == 2)
        #expect(m.maxSpeed2sRange == 0...2)
        #expect(m.maxSpeed10s == 2)
        #expect(m.maxSpeed10sRange == 0...10)
    }

    @Test func maxSpeedWindowsRespectTheirOwnGapLimits() {
        var engine = SessionEngine(sport: .sailing)
        let run = Run(speed: { $0 < 50 ? 8 : 10 })
        for t in [0.0, 3] { engine.ingest(.gps(run.fix(t))) }
        #expect(engine.snapshot.maxSpeed2s == nil)
        #expect(engine.snapshot.maxSpeed2sRange == nil)
        #expect(engine.snapshot.maxSpeed10s == nil)
        #expect(engine.snapshot.maxSpeed10sRange == nil)

        // Both early gaps exceed 2 s but are within the 10 s window's gap limit.
        engine.ingest(.gps(run.fix(10)))
        #expect(engine.snapshot.maxSpeed2sRange == nil)
        #expect(engine.snapshot.maxSpeed10s == 8)
        #expect(engine.snapshot.maxSpeed10sRange == 0...10)

        // A GPS re-anchor after a long gap cannot improve either best by interpolation.
        engine.ingest(.gps(run.fix(50)))
        #expect(engine.snapshot.maxSpeed2sRange == nil)
        #expect(engine.snapshot.maxSpeed10sRange == 0...10)

        for t in [51.0, 52] { engine.ingest(.gps(run.fix(t))) }
        #expect(engine.snapshot.maxSpeed2s == 10)
        #expect(engine.snapshot.maxSpeed2sRange == 50...52)
        #expect(engine.snapshot.maxSpeed10sRange == 0...10)

        engine.ingest(.gps(run.fix(60)))
        #expect(engine.snapshot.maxSpeed10s == 10)
        #expect(engine.snapshot.maxSpeed10sRange == 50...60)
    }

    @Test func overridingMaxSpeedClearsItsRange() {
        let fixes = Run(speed: { _ in 2 }).fixes(0...10)
        var m = simulate(.sailing, fixes.map(Sample.gps)).snapshot
        m.maxSpeed2s = 3
        #expect(m.maxSpeed2s == 3)
        #expect(m.maxSpeed2sRange == nil)
        #expect(m.maxSpeed10sRange == 0...10)
        m.maxSpeed10s = nil
        #expect(m.maxSpeed10sRange == nil)
    }

    @Test func currentSpeedBlanksWhenGPSGoesQuiet() {
        let fixes = Run(speed: { _ in 2 }).fixes(0...20)
        let hr = (0...40).map { Sample.hr(HRSample(t: Double($0), bpm: 120)) }
        let m = simulate(.kayak, fixes.map(Sample.gps) + hr).snapshot
        #expect(m.speed == nil)
        #expect(m.elapsed == 40)
    }

    @Test func heartRateAndStop() {
        let hr = [100.0, 140, 120, .nan, 0].enumerated().map {
            Sample.hr(HRSample(t: Double($0.offset), bpm: $0.element))
        }
        let late = Sample.gps(Run(speed: { _ in 2 }).fix(10))
        let engine = simulate(.sup, hr + [.event(SessionEvent(t: 5, type: .stop)), late])
        let m = engine.snapshot
        #expect(m.heartRate == 120)
        #expect(m.heartRateAverage == 120)
        #expect(m.heartRateMax == 140)
        #expect(m.isFinished)
        #expect(m.acceptedFixes == 0)
        #expect(m.elapsed == 5)
    }

    @Test func outOfOrderFixesAreRejected() {
        let run = Run(speed: { _ in 2 })
        var engine = SessionEngine(sport: .kayak)
        for t in [0, 1, 2, 1, 3] { engine.ingest(.gps(run.fix(Double(t)))) }
        #expect(engine.snapshot.rejectedFixes == 1)
        #expect(engine.snapshot.movingTime == 3)
    }

    @Test func standardProfiles() {
        for sport in Sport.allCases {
            let profile = SportProfile.standard(for: sport)
            #expect(profile.autoPause.enabled == sport.isPaddling)
            #expect(profile.savesWorkoutByDefault == (sport != .motorboating))
        }
    }

    // Regression test from the PR #25 review: with GPS quiet and no heart rate, the
    // current speed stayed at its last value because the clock never moved.
    @Test func advancingTheClockBlanksAStaleSpeed() {
        var engine = SessionEngine(sport: .kayak)
        for fix in Run(speed: { _ in 2 }).fixes(0...10) { engine.ingest(.gps(fix)) }
        #expect(approx(engine.snapshot.speed, 2))
        engine.advance(to: 20)
        #expect(engine.snapshot.speed == nil)
        #expect(engine.snapshot.elapsed == 20)
        engine.advance(to: 15)
        engine.advance(to: .nan)
        #expect(engine.snapshot.elapsed == 20)
        engine.ingest(.event(SessionEvent(t: 21, type: .stop)))
        engine.advance(to: 30)
        #expect(engine.snapshot.elapsed == 21)
    }

    // Regression tests from the PR #23 review.

    @Test func manualResumeDoesNotCountThePausedInterval() {
        let run = Run(speed: { _ in 2 })
        let samples: [Sample] = [
            .gps(run.fix(0)), .event(SessionEvent(t: 1, type: .pause)), .event(SessionEvent(t: 9, type: .resume)),
            .gps(run.fix(10)), .gps(run.fix(11)),
        ]
        let m = simulate(.sailing, samples).snapshot
        #expect(m.movingTime == 1)
        #expect(approx(m.distance, 2))
    }

    @Test func autoPauseDoesNotRollBackClosedLaps() {
        let run = Run(speed: { _ in 0.2 })
        let samples = run.fixes(0...12).map(Sample.gps) + [.event(SessionEvent(t: 5.5, type: .lap))]
        let engine = simulate(.kayak, samples)
        let m = engine.snapshot
        #expect(m.pauseState == .autoPaused)
        #expect(m.laps.count == 1)
        // The pause is dated back to the lap boundary, so the session total still
        // covers the closed lap and the current lap is empty, not negative.
        #expect(m.movingTime == m.laps[0].movingTime)
        #expect(approx(m.distance, m.laps[0].distance, tolerance: 1e-9))
        #expect(m.currentLap.movingTime == 0)
        #expect(engine.generatedEvents.map(\.t) == [5.5])
    }

    @Test func reanchorDoesNotSatisfyResumeHold() {
        let still = Run(speed: { _ in 0 })
        let samples = still.fixes(0...12).map(Sample.gps) + [.gps(Run(speed: { _ in 2 }).fix(100))]
        let engine = simulate(.kayak, samples)
        #expect(engine.generatedEvents.map(\.type) == [.pause])
        #expect(engine.snapshot.pauseState == .autoPaused)
    }

    @Test func nonFiniteTimesAreIgnored() {
        let run = Run(speed: { _ in 2 })
        var bad = run.fix(1)
        bad.t = .nan
        let samples: [Sample] = [
            .gps(run.fix(0)), .gps(bad), .gps(run.fix(2)), .hr(HRSample(t: .infinity, bpm: 150)),
            .event(SessionEvent(t: .nan, type: .stop)),
        ]
        var engine = SessionEngine(sport: .kayak)
        for sample in samples { engine.ingest(sample) }
        let m = engine.snapshot
        #expect(m.movingTime == 2)
        #expect(m.elapsed == 2)
        #expect(m.rejectedFixes == 0)
        #expect(m.heartRate == nil)
        #expect(!m.isFinished)
        var filter = GPSFilter()
        #expect(filter.ingest(bad) == .rejected(.invalidTime))
    }
}

@Suite struct SessionReplayTests {
    private static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    private func track(_ fixes: [GPSFix], events: [SessionEvent] = [], sport: Sport = .kayak) -> Track {
        Track(sessionId: Self.id, sport: sport, startedAt: Date(timeIntervalSince1970: 0), gps: fixes, events: events)
    }

    @Test func matchesTheLiveEngine() {
        let fixes = Run(speed: { t in t < 60 || t >= 100 ? 1.5 : 0 }).fixes(0...159)
        var live = SessionEngine(sport: .kayak)
        for fix in fixes { live.ingest(.gps(fix)) }
        let replay = SessionReplay(track: track(fixes))
        #expect(replay.metrics == live.snapshot)
        #expect(replay.events == live.generatedEvents)
        #expect(replay.fixes.count == 160)
    }

    @Test(arguments: [2.0, 10.0]) func irregularFixesKeepTheRangeOfTheDisplayedCausalBest(window: Double) {
        let scale = window / 2
        let fixes = [(0.0, 2.0), (1, 6), (2.5, 0)].map { time, speed in
            GPSFix(t: time * scale, latitude: 0, longitude: 0, horizontalAccuracy: 5, speed: speed)
        }
        let recording = track(fixes, sport: .windsurfing)
        let replay = SessionReplay(track: recording)
        let offline = SessionStats(track: recording)
        let isShort = window == 2
        let mean = isShort ? replay.metrics.maxSpeed2s : replay.metrics.maxSpeed10s
        let range = isShort ? replay.metrics.maxSpeed2sRange : replay.metrics.maxSpeed10sRange

        #expect(replay.fixes == fixes)
        // The causal window ends at the last fix, with an interpolated start at 4 m/s.
        #expect(mean == 3.5)
        #expect(range == (0.5 * scale)...(2.5 * scale))
        // waterkit-replay shows the same value as live and session detail.
        #expect((isShort ? offline.maxSpeed2s : offline.maxSpeed10s) == mean)
    }

    @Test func storedAutoEventsAreRegeneratedNotReplayed() {
        let fixes = Run(speed: { t in t < 60 || t >= 100 ? 1.5 : 0 }).fixes(0...159)
        let stored = [
            SessionEvent(t: 60, type: .pause, data: ["auto": true]),
            SessionEvent(t: 99, type: .resume, data: ["auto": true]),
            SessionEvent(t: 120, type: .mark),
        ]
        let replay = SessionReplay(track: track(fixes, events: stored))
        let plain = SessionReplay(track: track(fixes))
        #expect(replay.metrics.movingTime == plain.metrics.movingTime)
        #expect(replay.events.map(\.type) == [.pause, .resume, .mark])
    }

    @Test func stopAtTheLastFixKeepsIt() {
        let fixes = Run(speed: { _ in 2 }).fixes(0...10)
        let replay = SessionReplay(track: track(fixes, events: [SessionEvent(t: 10, type: .stop)]))
        #expect(replay.metrics.movingTime == 10)
        #expect(replay.metrics.isFinished)
    }

    @Test func rejectedFixesAreLeftOut() {
        var fixes = Run(speed: { _ in 2 }).fixes(0...10)
        fixes[5].horizontalAccuracy = 80
        fixes[5].speed = 20
        let replay = SessionReplay(track: track(fixes))
        #expect(replay.fixes.map(\.t) == [0, 1, 2, 3, 4, 6, 7, 8, 9, 10])
        #expect(replay.metrics.maxSpeed2s == 2)
        #expect(replay.metrics.maxSpeed2sRange == 0...2)
        #expect(replay.metrics.maxSpeed10s == 2)
        #expect(replay.metrics.maxSpeed10sRange == 0...10)
    }

    @Test func analyzedTrackCarriesSummaryAndRoundTrips() throws {
        let fixes = Run(speed: { t in t < 60 || t >= 100 ? 1.5 : 0 }).fixes(0...159)
        let recorded = track(fixes, events: [SessionEvent(t: 30, type: .lap)])
        let replay = SessionReplay(track: recorded)
        let analyzed = replay.analyzedTrack(from: recorded)
        #expect(analyzed.analyzerVersion == SessionReplay.analyzerVersion)
        #expect(analyzed.events.map(\.type) == [.lap, .pause, .resume])
        guard case .object(let summary) = analyzed.summary else {
            Issue.record("summary is not an object")
            return
        }
        #expect(summary["movingTime"] == .number(replay.metrics.movingTime))
        #expect(summary["distance"] == .number(replay.metrics.distance))
        #expect(summary["maxSpeed2s"] == replay.metrics.maxSpeed2s.map(JSONValue.number))
        #expect(summary["maxSpeed10s"] == replay.metrics.maxSpeed10s.map(JSONValue.number))
        let expectedKeys: Set = [
            "distance", "movingTime", "elapsed", "laps", "averageSpeed", "maxSpeed2s", "maxSpeed10s",
        ]
        #expect(Set(summary.keys) == expectedKeys)
        if case .array(let laps) = summary["laps"] { #expect(laps.count == 2) } else { Issue.record("no laps") }
        let decoded = try TrackCodec.decode(TrackCodec.encode(analyzed))
        #expect(decoded.summary == analyzed.summary)
        #expect(decoded.analyzerVersion == "1.1.0")
        #expect(decoded.events.map(\.type) == analyzed.events.map(\.type))
    }
}
