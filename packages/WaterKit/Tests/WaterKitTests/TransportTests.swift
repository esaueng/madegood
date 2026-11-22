import Foundation
import Testing

@testable import WaterKit

/// 1 Hz fixes heading east from (0, 0), with positions that agree with the Doppler speed
/// (the step to each fix is the speed of the second before it), like a real vehicle leg.
struct TransportLeg {
    var speed: @Sendable (Double) -> Double

    func fixes(_ range: ClosedRange<Int>) -> [GPSFix] {
        var along = 0.0
        var fixes: [GPSFix] = []
        for second in range {
            let t = Double(second)
            if second > range.lowerBound { along += speed(t - 1) }
            let point = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: along)
            fixes.append(
                GPSFix(
                    t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: speed(t),
                    speedAccuracy: 0.3, course: 90))
        }
        return fixes
    }
}

private func run(_ samples: [Sample], profile: SportProfile) -> SessionEngine {
    var engine = SessionEngine(profile: profile)
    for sample in samples.sorted(by: { $0.t < $1.t }) { engine.ingest(sample) }
    return engine
}

private func approx(_ a: Double?, _ b: Double, tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance * max(1, abs(b))
}

/// Regression tests from a real kayak session (docs/metrics.md "Transport"): the watch kept
/// recording after landing, while the paddler walked to a car and drove off. The drive
/// auto-resumed the session and reported a max speed of 19 m/s (37 kn) over 10 s, and
/// added the drive to distance.
@Suite struct TransportTests {
    /// The session's pattern: paddle, land (auto-pause), walk with the boat (one stretch
    /// fast enough to auto-resume), get into the car, a slow road below the limit (30 s;
    /// the real car took 33 s from its stop to the limit), a stretch above it, a slower
    /// one, then a fast road at 18.5 m/s.
    static let landingAndDrive = TransportLeg { t in
        switch t {
        case ..<120: 1.9
        case ..<180: 0.1
        case ..<200: 0.6
        case ..<206: 0.9
        case ..<210: 0.6
        case ..<213: 0.2
        case ..<220: 1 + (t - 213)
        case ..<240: 7
        case ..<245: 7 + 0.4 * (t - 239)
        case ..<260: 9
        case ..<270: 6
        default: min(18.5, 6 + (t - 269))
        }
    }

    @Test func aVehicleLegIsLeftOutBackToTheLastStop() {
        let fixes = Self.landingAndDrive.fixes(0...399)
        let hr = stride(from: 0.0, through: 395, by: 5).map { (t: Double) -> Sample in
            let bpm: Double = t < 212 ? 140 : (t == 220 ? 150 : 100)
            return Sample.hr(HRSample(t: t, bpm: bpm))
        }
        let engine = run(fixes.map(Sample.gps) + hr, profile: .standard(for: .kayak))
        let m = engine.snapshot

        // Landing pauses at 120; walking at 0.9 m/s resumes from 199; the car's first leg
        // is dated back to the last fix below 0.8 m/s (212), before it crossed 8 m/s.
        #expect(engine.generatedEvents.map(\.type) == [.pause, .resume, .pause])
        #expect(engine.generatedEvents.map(\.t) == [120, 199, 212])
        #expect(engine.generatedEvents.last?.data == ["auto": true, "transport": true])
        #expect(engine.transportIntervals == [212...399])
        #expect(m.pauseState == .autoPaused)

        let paddled: Double = 1.9 * 120
        let walked: Double = 0.6 + 0.9 * 6 + 0.6 * 4 + 0.2 * 2
        #expect(m.movingTime == 133)
        #expect(approx(m.distance, paddled + walked))
        // Max speeds are the paddle's, not the car's (it was 18.5 m/s for both).
        #expect(approx(m.maxSpeed2s, 1.9))
        #expect(approx(m.maxSpeed10s, 1.9))
        #expect(m.maxSpeed2sRange.map { $0.upperBound <= 212 } == true)
        #expect(m.maxSpeed10sRange.map { $0.upperBound <= 212 } == true)
        // Heart rate in the car (including 150 bpm before the limit was crossed) is out.
        #expect(m.heartRateAverage == 140)
        #expect(m.heartRateMax == 140)
        #expect(m.heartRate == 100)
    }

    @Test func replayMatchesLiveAndStoresTheTransportEvent() {
        let fixes = Self.landingAndDrive.fixes(0...399)
        var live = SessionEngine(sport: .kayak)
        for fix in fixes { live.ingest(.gps(fix)) }
        let track = Track(
            sessionId: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, sport: .kayak,
            startedAt: Date(timeIntervalSince1970: 0), gps: fixes)
        let replay = SessionReplay(track: track)
        #expect(replay.metrics == live.snapshot)
        #expect(replay.events == live.generatedEvents)
        #expect(replay.transportIntervals == [212...399])
        // Stored auto events are regenerated, not replayed.
        let reanalyzed = SessionReplay(track: replay.analyzedTrack(from: track))
        #expect(reanalyzed.metrics == replay.metrics)
        #expect(reanalyzed.events == replay.events)
    }

    @Test func aSurfOnAWaveIsNotTransport() {
        // 6 s at 9 m/s is a burst, not a vehicle: it stays in the max speeds.
        let fixes = TransportLeg { t in (100..<106).contains(t) ? 9 : 2 }.fixes(0...199)
        let engine = run(fixes.map(Sample.gps), profile: .standard(for: .kayak))
        #expect(engine.generatedEvents.isEmpty)
        #expect(engine.transportIntervals.isEmpty)
        #expect(approx(engine.snapshot.maxSpeed2s, 9))
        #expect(engine.snapshot.movingTime == 199)
    }

    @Test func withoutAutoPauseTheSessionResumesWhenTheVehicleStops() {
        // Drove to another put-in without stopping the recording.
        let leg = TransportLeg { t in
            switch t {
            case ..<60: 2
            case ..<65: 0.2
            case ..<75: min(10, 1 + (t - 65))
            case ..<120: 10
            case ..<130: max(0.5, 10 - (t - 119))
            default: 2
            }
        }
        var profile = SportProfile.standard(for: .kayak)
        profile.autoPause.enabled = false
        let engine = run(leg.fixes(0...199).map(Sample.gps), profile: profile)
        let m = engine.snapshot
        #expect(engine.generatedEvents.map(\.type) == [.pause, .resume])
        #expect(engine.generatedEvents.map(\.t) == [64, 129])
        #expect(engine.transportIntervals == [64...129])
        #expect(m.pauseState == .moving)
        #expect(m.movingTime == 134)
        let before: Double = 2 * 60 + 0.2 * 4
        let after: Double = 0.5 + 2 * 69
        #expect(approx(m.distance, before + after))
        #expect(approx(m.maxSpeed2s, 2))
        #expect(approx(m.maxSpeed10s, 2))
    }

    @Test func aDriveDuringAManualPauseLeavesTheMaxSpeeds() {
        // Pauses do not stop the max speeds, but a vehicle leg does, paused or not.
        let leg = TransportLeg { t in t < 60 ? 2 : (t < 65 ? 0.2 : min(19, 1 + (t - 65))) }
        let samples = leg.fixes(0...199).map(Sample.gps) + [.event(SessionEvent(t: 62.5, type: .pause))]
        let engine = run(samples, profile: .standard(for: .kayak))
        let m = engine.snapshot
        #expect(m.pauseState == .manuallyPaused)
        #expect(engine.generatedEvents.isEmpty)
        #expect(engine.transportIntervals == [64...199])
        #expect(approx(m.maxSpeed2s, 2))
        #expect(approx(m.maxSpeed10s, 2))
        // A manual resume in the car ends the leg, but the drive is confirmed again from
        // the next fix and does not count.
        var resumed = engine
        resumed.ingest(.event(SessionEvent(t: 200, type: .resume)))
        for fix in leg.fixes(0...215).suffix(15) { resumed.ingest(.gps(fix)) }
        #expect(resumed.snapshot.pauseState == .autoPaused)
        #expect(resumed.snapshot.movingTime == m.movingTime)
        #expect(resumed.transportIntervals == [64...200, 201...215])
        #expect(approx(resumed.snapshot.maxSpeed2s, 2))
    }

    @Test func otherSportsHaveNoSpeedLimit() {
        let fixes = Self.landingAndDrive.fixes(0...399)
        for sport in [Sport.sailing, .windsurfing, .motorboating] {
            let engine = run(fixes.map(Sample.gps), profile: .standard(for: sport))
            #expect(engine.transportIntervals.isEmpty)
            #expect(approx(engine.snapshot.maxSpeed2s, 18.5))
        }
    }
}

/// Regression tests from the PR #168 review.
@Suite struct TransportReviewTests {
    /// Finding 1: the paddler lands, drives off, and taps Pause six seconds after the car
    /// passed the limit, before the leg is confirmed. The driving before the tap must not
    /// stay in distance, moving time or splits.
    @Test func aManualPauseBeforeConfirmationStillRollsBackTheDrive() {
        let leg = TransportLeg { t in t < 60 ? 2 : (t < 65 ? 0.2 : min(12, 1 + (t - 65))) }
        // Above 8 m/s from t = 73; paused at 78.5; confirmed at 83.
        let fixes = leg.fixes(0...120)
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0), gps: fixes,
            events: [SessionEvent(t: 78.5, type: .pause)])
        let replay = SessionReplay(track: track)
        let m = replay.metrics
        #expect(m.pauseState == .manuallyPaused)
        #expect(m.movingTime == 64)
        let paddled: Double = 2 * 60 + 0.2 * 4
        #expect(abs(m.distance - paddled) < 1e-6)
        #expect(abs((m.maxSpeed2s ?? 0) - 2) < 1e-9)
        #expect(replay.events.map(\.type) == [.pause, .pause])
        #expect(replay.events.first?.t == 64)
        #expect(replay.events.first?.data == ["auto": true, "transport": true])
        #expect(replay.transportIntervals == [64...120])
        let splitDistance = replay.paddlingSplits.reduce(0.0) { $0 + $1.distance }
        #expect(abs(splitDistance - paddled) < 1e-6)
    }

    /// Finding 2: two fast fixes either side of a GPS gap are not an observed 10 s hold.
    @Test func aGapDoesNotConfirmTheHold() {
        // 31 s re-anchors the GPS; 10 s does not, but is still unobserved.
        for gap in [51...80, 51...59] {
            let leg = TransportLeg { t in t == 50 || t == Double(gap.upperBound + 1) ? 9 : 2 }
            let fixes = leg.fixes(0...120).filter { !gap.contains(Int($0.t)) }
            let engine = run(fixes.map(Sample.gps), profile: .standard(for: .kayak))
            #expect(engine.transportIntervals.isEmpty)
            #expect(engine.generatedEvents.isEmpty)
        }
    }

    /// Finding 2: a drive through a tunnel (a GPS re-anchor) still rolls back to the stop
    /// before the drive, not to the anchor, so the driving before the gap is left out.
    @Test func aDriveThroughAGPSGapRollsBackToTheStopBeforeIt() {
        let leg = TransportLeg { t in t < 60 ? 2 : (t < 65 ? 0.2 : min(9, 1 + (t - 65))) }
        let fixes = leg.fixes(0...140).filter { !(76...106).contains(Int($0.t)) }
        let engine = run(fixes.map(Sample.gps), profile: .standard(for: .kayak))
        let m = engine.snapshot
        #expect(engine.transportIntervals == [64...140])
        #expect(engine.generatedEvents.map(\.t) == [64])
        #expect(m.movingTime == 64)
        let paddled: Double = 2 * 60 + 0.2 * 4
        #expect(approx(m.distance, paddled))
        #expect(approx(m.maxSpeed2s, 2))
        #expect(approx(m.maxSpeed10s, 2))
    }

    /// Finding 3: paused before driving, resumed in the car. The engine's events must say
    /// what it counts, so heart-rate zones and strokes (which read the events) agree with
    /// moving time, during the drive and while auto-paused after the car stops.
    @Test func aManualResumeInTheCarKeepsDetailMetricsInStep() {
        let leg = TransportLeg { t in
            switch t {
            case ..<60: 2
            case ..<65: 0.2
            case ..<150: min(19, 1 + (t - 65))
            case ..<170: max(0.3, 19 - 2 * (t - 150))
            default: 2
            }
        }
        let fixes = leg.fixes(0...260)
        let hr = (0...260).map { HRSample(t: Double($0), bpm: 150) }
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0), gps: fixes, hr: hr,
            events: [SessionEvent(t: 62.5, type: .pause), SessionEvent(t: 100, type: .resume)])
        let replay = SessionReplay(track: track)
        let m = replay.metrics

        #expect(replay.transportIntervals == [64...100, 101...160])
        #expect(replay.events.map(\.type) == [.pause, .resume, .pause, .resume])
        #expect(replay.events.map(\.t) == [62.5, 100, 101, 169])
        #expect(m.movingTime == 62 + (260 - 169))
        #expect(approx(m.maxSpeed2s, 2))
        // Strokes are gated by these (manual pauses by the detector itself).
        #expect(replay.autoPausedIntervals == [64...100, 101...169])
        // Heart-rate zones read the same events: the drive and the stop after it are out.
        let zones = HeartRateZones().durations(samples: hr, events: replay.events, spans: [0...260])
        let zoneTime = zones.values.reduce(0, +)
        #expect(abs(zoneTime - m.movingTime) <= 2.5)
    }

    /// Finding 5: a paddler who really holds 8.5 m/s for 11 s (a downwind foil, a fast
    /// current) after paddling without a stop since the start loses at most the 60 s
    /// before the run, not the whole session.
    @Test func aFalseTriggerErasesAtMostTheLookback() {
        let leg = TransportLeg { t in
            switch t {
            case ..<300: 2
            case ..<311: 8.5
            case ..<312: 4
            case ..<320: 0.5
            default: 2
            }
        }
        let engine = run(leg.fixes(0...400).map(Sample.gps), profile: .standard(for: .kayak))
        let m = engine.snapshot
        #expect(engine.transportIntervals == [240...312])
        #expect(engine.generatedEvents.map(\.t) == [240, 319])
        #expect(m.movingTime == 240 + (400 - 319))
        let paddled: Double = 2 * 240 + 0.5 + 2 * 80
        #expect(approx(m.distance, paddled))
        #expect(approx(m.maxSpeed2s, 2))
    }

    /// Re-check finding: a manual pause and resume during the unconfirmed hold. The raw
    /// resume must not reopen the rolled-back leg for heart-rate zones or the stroke gate.
    @Test func aPauseAndResumeBeforeConfirmationStayRolledBack() {
        let leg = TransportLeg { t in t < 60 ? 2 : (t < 65 ? 0.2 : min(12, 1 + (t - 65))) }
        // Last slow fix 64; above 8 m/s from 73; pause 78.5, resume 80; confirmed at 83.
        let hr = (0...120).map { HRSample(t: Double($0), bpm: 150) }
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0), gps: leg.fixes(0...120),
            hr: hr, events: [SessionEvent(t: 78.5, type: .pause), SessionEvent(t: 80, type: .resume)])
        let replay = SessionReplay(track: track)
        let m = replay.metrics
        #expect(m.movingTime == 64)
        #expect(replay.transportIntervals == [64...120])
        #expect(replay.events.map(\.type) == [.pause, .pause, .resume, .pause])
        #expect(replay.events.map(\.t) == [64, 78.5, 80, 81])
        let zones = HeartRateZones().durations(samples: hr, events: replay.events, spans: [0...120])
        let zoneTime = zones.values.reduce(0, +)
        // Zones count 0–64 s and the 1 s from the resume to the next fix, nothing after.
        #expect(abs(zoneTime - m.movingTime) <= 1.5)
        #expect(replay.autoPausedIntervals == [64...Double.infinity])
    }
}
