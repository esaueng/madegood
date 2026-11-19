import Foundation
import Testing

@testable import WaterKit

/// 1 Hz fixes heading east from (0, 0) at `speed(t)`; position steps match the speeds.
private func motorFixes(_ range: ClosedRange<Int>, speed: (Double) -> Double) -> [GPSFix] {
    var along = 0.0
    var fixes: [GPSFix] = []
    for second in range {
        let t = Double(second)
        let point = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: along)
        fixes.append(GPSFix(t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: speed(t)))
        along += speed(t)
    }
    return fixes
}

private func run(_ sport: Sport, _ samples: [Sample], autoPause: Bool? = nil) -> LiveMetrics {
    var profile = SportProfile.standard(for: sport)
    if let autoPause { profile.autoPause.enabled = autoPause }
    var engine = SessionEngine(profile: profile)
    for sample in samples.sorted(by: { $0.t < $1.t }) { engine.ingest(sample) }
    return engine.snapshot
}

@Suite struct MotorboatTests {
    /// 100 s at 8 m/s (planing), 60 s idling at 0.3 m/s, 40 s at 8 m/s.
    private static let trip = motorFixes(0...199) { t in t < 100 || t >= 160 ? 8 : 0.3 }

    @Test func engineTimeCountsOnlyIntervalsUnderWay() {
        let m = run(.motorboating, Self.trip.map(Sample.gps))
        #expect(m.movingTime == 199)
        // Intervals 0–99 (99 s) and 160–199 (39 s) are under way. The two transition
        // intervals average (8 + 0.3) / 2 = 4.15 m/s, so they count too: 99 + 1 + 1 + 39.
        #expect(m.underWayTime == 140)
    }

    @Test func engineTimeSkipsManualPausesAndRecoveryGaps() {
        var samples = Self.trip.map(Sample.gps)
        samples.append(.event(SessionEvent(t: 20.5, type: .pause)))
        samples.append(.event(SessionEvent(t: 40.5, type: .resume)))
        let m = run(.motorboating, samples)
        // 21–40 is paused and the interval spanning the resume is not counted (20 + 1 s).
        #expect(m.underWayTime == 140 - 21)

        // A 41 s outage (49 → 90) re-anchors the filter: the step across it is not engine time.
        let gap = Self.trip.filter { $0.t < 50 || $0.t >= 90 }
        #expect(run(.motorboating, gap.map(Sample.gps)).underWayTime == 140 - 41)
    }

    @Test func engineTimeFollowsAutoPauseRollback() {
        // With auto-pause on, a long stop is removed from moving time; the rollback must
        // not leave engine time behind, nor lose it on resume.
        let fixes = motorFixes(0...159) { t in t < 60 || t >= 100 ? 3 : 0 }
        let m = run(.motorboating, fixes.map(Sample.gps), autoPause: true)
        #expect(m.underWayTime <= m.movingTime)
        // 0–59 under way (59 s + the 59–60 interval at 1.5 m/s mean), resumed from 99–100
        // (mean 1.5 m/s) to 159: 60 + 60.
        #expect(m.underWayTime == 120)
    }

    @Test func replayMatchesLiveEngineTime() {
        let track = Track(
            sessionId: UUID(), sport: .motorboating, startedAt: Date(timeIntervalSince1970: 0), gps: Self.trip,
            hr: [], events: [SessionEvent(t: 0, type: .start), SessionEvent(t: 199, type: .stop)])
        #expect(SessionReplay(track: track).metrics.underWayTime == 140)
    }

    @Test func fuelEstimateUsesBurnRatesAndLabelsIdleTime() throws {
        let model = FuelModel(burnRate: 36, idleBurnRate: 3.6)
        let estimate = try #require(model.estimate(underWayTime: 1800, movingTime: 2400))
        #expect(estimate.engineTime == 1800)
        #expect(estimate.idleTime == 600)
        #expect(abs(estimate.litres - (18 + 0.6)) < 1e-9)

        let m = run(.motorboating, Self.trip.map(Sample.gps))
        let fromMetrics = try #require(FuelModel(burnRate: 36).estimate(m))
        #expect(abs(fromMetrics.litres - 1.4) < 1e-9)  // 140 s at 36 L/h

        #expect(FuelModel(burnRate: 0).estimate(m) == nil)
        #expect(FuelModel(burnRate: .nan).estimate(m) == nil)
        #expect(FuelModel(burnRate: 10, idleBurnRate: -1).estimate(m) == nil)
        // Engine time can never exceed moving time in the estimate.
        #expect(model.estimate(underWayTime: 100, movingTime: 50)?.idleTime == 0)
    }

    @Test func nauticalLogAddsTripsInOrder() {
        let saved = [
            NauticalLog.Trip(startedAt: 100, distance: 1852),
            NauticalLog.Trip(startedAt: 300, distance: 3704),
            NauticalLog.Trip(startedAt: 200, distance: 926),
            NauticalLog.Trip(startedAt: 400, distance: .nan),
        ]
        let live = NauticalLog(trip: 500, saved: saved)
        #expect(live.trip == 500)
        #expect(live.total == 1852 + 3704 + 926 + 500)

        let second = NauticalLog(savedTrip: saved[2], all: saved)
        #expect(second.trip == 926)
        #expect(second.total == 1852 + 926)
        // A trip not in the list, or listed with another distance, counts itself once.
        let alone = NauticalLog(savedTrip: NauticalLog.Trip(startedAt: 250, distance: 10), all: saved)
        #expect(alone.total == 1852 + 926 + 10)
        let stale = NauticalLog(savedTrip: NauticalLog.Trip(startedAt: 200, distance: 1000), all: saved)
        #expect(stale.total == 1852 + 1000)
        #expect(NauticalLog(trip: -5, saved: []).total == 0)
    }

    @Test func volumeUnitsConvertExactly() {
        #expect(VolumeUnit.usGallons.toLitres(1) == 3.785411784)
        #expect(VolumeUnit.litres.display(12.34).text == "12.3 L")
        #expect(VolumeUnit.usGallons.display(37.85411784).text == "10.0 gal")
        #expect(VolumeUnit.litres.display(250).text == "250 L")
    }

    @Test func fuelSettingsRoundTripAndRejectNonsense() {
        var store: [String: Any] = [:]
        var settings = SportSettings.standard(for: .motorboating)
        #expect(settings.fuelModel == nil)
        settings.fuelBurnRate = 24
        settings.idleFuelBurnRate = 2
        settings.fuelUnit = .usGallons
        settings.write(sport: .motorboating) { key, value in store[key] = value }
        #expect(store["settings.fuelBurn.motorboating"] as? Double == 24)
        #expect(store["settings.fuelUnit.motorboating"] as? String == "galUS")
        let read = SportSettings(sport: .motorboating) { store[$0] }
        #expect(read == settings)
        #expect(read.fuelModel == FuelModel(burnRate: 24, idleBurnRate: 2))
        #expect(SettingsSync.storedKeys.contains("settings.fuelBurn.motorboating"))

        for bad: Any in [-3.0, 0.0, "abc", 1e9] {
            let parsed = SportSettings(sport: .motorboating) { $0 == "settings.fuelBurn.motorboating" ? bad : nil }
            #expect(parsed.fuelBurnRate == nil)
        }
        // Defaults are not stored.
        var cleared: [String: Any] = [:]
        SportSettings.standard(for: .motorboating).write(sport: .motorboating) { key, value in cleared[key] = value }
        #expect(cleared.isEmpty)
    }
}
