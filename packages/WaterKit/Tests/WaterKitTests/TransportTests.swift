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
    /// fast enough to auto-resume), get into the car, a slow road below the limit, a
    /// stretch above it, a slower one, then a fast road at 18.5 m/s.
    static let landingAndDrive = TransportLeg { t in
        switch t {
        case ..<120: 1.9
        case ..<180: 0.1
        case ..<200: 0.6
        case ..<206: 0.9
        case ..<210: 0.6
        case ..<213: 0.2
        case ..<220: 1 + (t - 213)
        case ..<280: 7
        case ..<285: 7 + 0.4 * (t - 279)
        case ..<300: 9
        case ..<310: 6
        default: min(18.5, 6 + (t - 309))
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
        // A manual resume in the car does not count the drive.
        var resumed = engine
        resumed.ingest(.event(SessionEvent(t: 200, type: .resume)))
        for fix in leg.fixes(0...210).suffix(10) { resumed.ingest(.gps(fix)) }
        #expect(resumed.snapshot.pauseState == .autoPaused)
        #expect(resumed.snapshot.movingTime == m.movingTime)
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
