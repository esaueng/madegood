import Foundation
import Testing

@testable import WaterKit

/// Regression tests from a real kayak session: strokes were counted while the session was
/// auto-paused (getting in, a stop, carrying the boat) and in the car afterwards, which
/// inflated the count, the average rate and distance per stroke against moving distance.
/// Post-session strokes now count in moving time only (docs/metrics.md "Strokes").
@Suite struct StrokeGatingTests {
    /// Wrist motion at 60 spm for 200 s throughout, while GPS shows paddling (0–60 s), a
    /// stop with the wrist still moving (60–100 s, auto-paused 60–99 s), paddling again,
    /// then a car leg from the last slow fix at 142 s.
    static func session() -> (RawSession, PaddleMotionSimulator.Output) {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 200, strokeRate: 60)])
        simulator.seed = 53
        let output = simulator.generate()
        let speed: @Sendable (Double) -> Double = { t in
            switch t {
            case ..<60: 2
            case ..<100: 0
            case ..<140: 2
            case ..<143: 0.2
            default: min(12, 1 + (t - 143))
            }
        }
        var along = 0.0
        let fixes = (0...199).map { second -> GPSFix in
            let t = Double(second)
            if second > 0 { along += speed(t - 1) }
            let point = Geo.destination(lat: 10, lon: -30, bearing: 90, distance: along)
            return GPSFix(
                t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: speed(t), course: 90)
        }
        let startUnix = 946_684_800.0
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: startUnix, endedAt: startUnix + 200,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"),
            requestedRates: [:])
        return (RawSession(meta: meta, gps: fixes, motion: output.samples), output)
    }

    @Test func strokesCountOnlyInMovingTime() throws {
        let (session, output) = Self.session()
        let selection = try SessionSelection(session: session)
        #expect(selection.replay.autoPausedIntervals == [60...99, 142...Double.infinity])

        let analysis = StrokeAnalysis(session: session, selection: selection)
        let moving = output.cycleTimes.filter { $0 < 60 || (99..<142).contains($0) }
        #expect(abs(analysis.strokeCount - 2 * moving.count) <= 4)
        #expect(analysis.strokes.allSatisfy { $0.t < 60 || (99..<142).contains($0.t) })
        // The detector itself still finds the cycles in the pauses (live counts them).
        #expect(StrokeAnalysis.detect(session: session).strokes.count > analysis.strokeCount + 80)
        #expect(analysis.averageStrokeRate.map { abs($0 - 60) <= 2 } == true)
        let distance = selection.replay.metrics.distance
        #expect(analysis.distancePerStroke.map { abs($0 - distance / Double(analysis.strokeCount)) < 1e-9 } == true)
        // Paddled at 2 m/s and 60 spm: 2 m per stroke.
        #expect(analysis.distancePerStroke.map { abs($0 - 2) < 0.1 } == true)
    }

    @Test func replayStatsMatchSessionDetail() throws {
        let (session, _) = Self.session()
        let selection = try SessionSelection(session: session)
        let detail = StrokeAnalysis(session: session, selection: selection)
        let stats = SessionStats(session: session)
        #expect(stats.strokes?.count == detail.strokeCount)
        #expect(stats.strokes?.averageRate == detail.averageStrokeRate)
        #expect(stats.strokes?.distancePerStroke == detail.distancePerStroke)
        #expect(stats.movingDistance == selection.replay.metrics.distance)
        #expect(stats.movingTime == selection.replay.metrics.movingTime)
        #expect(stats.maxSpeed2s.map { abs($0 - 2) < 1e-9 } == true)
    }

    @Test func cuttingPausesOutOfRanges() {
        let ranges = StrokeAnalysis.ranges([0...100], excluding: [10...20, 15...30, 90...120])
        #expect(ranges == [0...10.0.nextDown, 30...90.0.nextDown])
        #expect(StrokeAnalysis.ranges([0...100], excluding: []) == [0...100])
        #expect(StrokeAnalysis.ranges([0...10, 20...30], excluding: [5...25]) == [0...5.0.nextDown, 25...30])
    }

    @Test func autoPausedIntervalsCloseAtCutsAndManualEvents() {
        let events = [
            SessionEvent(t: 10, type: .pause, data: ["auto": true]),
            SessionEvent(t: 20, type: .resume, data: ["auto": true]),
            SessionEvent(t: 30, type: .pause, data: ["auto": true]),
            SessionEvent(t: 50, type: .pause),
            SessionEvent(t: 60, type: .resume),
            SessionEvent(t: 70, type: .pause, data: ["auto": true]),
        ]
        let intervals = SessionReplay.autoPausedIntervals(
            events: events + [SessionEvent(t: 120, type: .stop)], transport: [100...130], removed: [80...90], end: 140)
        #expect(intervals == [10...20, 30...50, 70...80, 100...130])
    }
}
