import Testing

@testable import WaterKit

@Suite struct HeartRateZonesTests {
    @Test func classifiesInclusiveLowerBoundsAndReadingsAboveMaximum() {
        let zones = HeartRateZones(maximum: 195)
        #expect(zones.zone(for: 116.99) == .one)
        #expect(zones.zone(for: 117) == .two)
        #expect(zones.zone(for: 136.5) == .three)
        #expect(zones.zone(for: 156) == .four)
        #expect(zones.zone(for: 175.5) == .five)
        #expect(zones.zone(for: 201) == .five)
        #expect(zones.zone(for: 0) == nil)
        #expect(zones.zone(for: .infinity) == nil)
    }

    @Test func validatesMaximumAndThresholdsIndependently() {
        let custom = [50, 65, 75, 85]
        #expect(HeartRateZones(maximum: 200, thresholds: custom).zone(for: 100) == .two)
        #expect(HeartRateZones(maximum: 0, thresholds: custom).thresholds == custom)
        #expect(HeartRateZones(maximum: 0, thresholds: custom).maximum == HeartRateZones.defaultMaximum)
        for invalid in [[60, 70], [60, 70, 70, 90], [60, 80, 70, 90], [0, 70, 80, 90], [60, 70, 80, 101]] {
            let zones = HeartRateZones(maximum: 200, thresholds: invalid)
            #expect(zones.maximum == 200)
            #expect(zones.thresholds == HeartRateZones.defaultThresholds)
        }
    }

    @Test func sumsUnevenIntervalsWithoutBridgingGapsOrInvalidReadings() throws {
        let selection = try self.selection(
            [
                (41, 160), (2, 100), (4, 130), (9, 190), (25, 170), (40, 130), (40, 150), (42, .nan),
                (44, 185), (45, 185), (51, 185),
            ],
            events: [.init(t: 50, type: .stop)])
        #expect(HeartRateZones(maximum: 200).durations(in: selection) == [.one: 2, .two: 5, .three: 1, .four: 15, .five: 1])
        #expect(HeartRateZones().durations(in: try self.selection([(4, 140)])).isEmpty)
    }

    @Test func clipsAtPauseAndWaitsForAReadingAfterResume() throws {
        let selection = try self.selection(
            [(0, 100), (5, 120), (10, 140), (15, 160), (20, 180), (25, 200)],
            events: [.init(t: 7, type: .pause), .init(t: 13, type: .resume), .init(t: 20, type: .pause)])
        #expect(HeartRateZones(maximum: 200).durations(in: selection) == [.one: 5, .two: 2, .four: 5])
    }

    @Test func waitsForAReadingAfterAShortPauseBetweenSamples() throws {
        let selection = try self.selection(
            [(0, 100), (5, 120), (10, 140)],
            events: [.init(t: 2, type: .pause), .init(t: 4, type: .resume)])
        #expect(HeartRateZones(maximum: 200).durations(in: selection) == [.one: 2, .two: 5])
    }

    @Test func respectsRetainedSpansAndPauseStateAtTheirBoundaries() throws {
        let samples = (0...10).map { (Double($0), 100.0) }
        let trim = try SessionTrim(start: 1, end: 10, removing: [3...6])
        let resumedInsideCut = try selection(
            samples, events: [.init(t: 2, type: .pause), .init(t: 5, type: .resume)], trim: trim)
        #expect(HeartRateZones().durations(in: resumedInsideCut) == [.one: 5])
        let resumedAfterCut = try selection(
            samples, events: [.init(t: 2, type: .pause), .init(t: 8, type: .resume)], trim: trim)
        #expect(HeartRateZones().durations(in: resumedAfterCut) == [.one: 3])
    }

    @Test func usesRegeneratedAutoPauseEvents() throws {
        let times = (0...9).map(Double.init)
        let raw = RawSession(
            meta: RawSessionReaderTests.meta(),
            gps: times.map {
                GPSFix(
                    t: $0, latitude: 0, longitude: $0 * 0.000_01,
                    horizontalAccuracy: 3, speed: $0 < 6 ? 0.1 : 2, course: 90)
            },
            hr: times.map { HRSample(t: $0, bpm: 100) })
        var profile = SportProfile.standard(for: .kayak)
        profile.autoPause.pauseAfter = 2
        profile.autoPause.resumeAfter = 1
        let trim = try SessionTrim(start: 2, end: 8)
        #expect(
            HeartRateZones().durations(in: try SessionSelection(session: raw, trim: trim, profile: profile)) == [
                .one: 3
            ])
        profile.autoPause.enabled = false
        #expect(
            HeartRateZones().durations(in: try SessionSelection(session: raw, trim: trim, profile: profile)) == [
                .one: 6
            ])
    }

    private func selection(
        _ readings: [(Double, Double)], events: [SessionEvent] = [], trim: SessionTrim? = nil
    ) throws -> SessionSelection {
        try SessionSelection(
            session: RawSession(
                meta: RawSessionReaderTests.meta(endedAt: nil), hr: readings.map(HRSample.init), events: events),
            trim: trim)
    }
}
