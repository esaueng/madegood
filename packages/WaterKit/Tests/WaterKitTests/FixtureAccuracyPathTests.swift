import Foundation
import Testing

@testable import WaterKit

/// Review of #168: the PLAN §5 stroke checks must score what session detail shows, after
/// its moving-time gating, not the raw detector output.
@Suite struct FixtureAccuracyPathTests {
    /// 120 s of kayak wrist motion at 60 spm with GPS from `speed`, as a recording.
    static func session(speed: @escaping @Sendable (Double) -> Double) -> (RawSession, Int) {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 120, strokeRate: 60)])
        simulator.seed = 59
        let output = simulator.generate()
        var along = 0.0
        let fixes = (0...119).map { second -> GPSFix in
            let t = Double(second)
            if second > 0 { along += speed(t - 1) }
            let point = Geo.destination(lat: 10, lon: -30, bearing: 90, distance: along)
            return GPSFix(
                t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: speed(t), course: 90)
        }
        let startUnix = 946_684_800.0
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: startUnix, endedAt: startUnix + 120,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"),
            requestedRates: [:])
        return (RawSession(meta: meta, gps: fixes, motion: output.samples), output.strokeCount)
    }

    @Test func aPaddledRecordingMeetsTheThresholdsOnTheSessionDetailPath() throws {
        let (session, strokes) = Self.session { _ in 2 }
        try FixtureAccuracyTests.check(
            .init(strokes: strokes, strokeRateSPM: 60), session: session, context: "synthetic paddle")
    }

    @Test func strokesSessionDetailLeavesOutFailTheThresholds() throws {
        // The same wrist motion, but GPS says it all happened in a car: session detail
        // counts none of it, so the labeled count must not pass.
        let (session, strokes) = Self.session { t in t < 1 ? 0.2 : min(12, 1 + t) }
        #expect(StrokeAnalysis.detect(session: session).strokes.count >= strokes - 4)
        withKnownIssue("session detail leaves out strokes in a vehicle leg") {
            try FixtureAccuracyTests.check(
                .init(strokes: strokes, strokeRateSPM: 60), session: session, context: "synthetic drive")
        }
    }
}
