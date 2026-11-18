import Foundation
import Testing

@testable import WaterKit

@Suite struct SessionReplayTimelineTests {
    @Test func usesRecordingTimeAndAcceptedDopplerReadings() throws {
        let track = syntheticTrack([
            fix(10, metres: 0, speed: 2),
            fix(10.5, metres: 100, speed: 20, accuracy: 100),
            fix(11, metres: 2, speed: 4),
            fix(12, metres: 6, speed: nil),
            fix(13, metres: 9, speed: 3),
        ])
        let replay = SessionReplay(track: track)
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)

        #expect(timeline.duration == 25)
        #expect(timeline.points.map(\.elapsed) == [10, 11, 12, 13])
        #expect(timeline.selection(at: 5).position == nil)
        #expect(timeline.selection(at: 5).routeDistance == 0)
        let middle = timeline.selection(at: 10.5)
        #expect(middle.elapsed == 10.5)
        #expect(middle.speed == 3)
        #expect(abs(middle.routeDistance - 1) < 0.001)
        let position = try #require(middle.position)
        #expect(abs(Geo.distance(lat1: 0, lon1: 0, lat2: position.latitude, lon2: position.longitude) - 1) < 0.001)
        #expect(timeline.selection(at: 11.5).position != nil)
        #expect(timeline.selection(at: 11.5).speed == nil)
        #expect(timeline.selection(at: 12).speed == nil)
        #expect(timeline.selection(at: 13).speed == 3)
        let end = timeline.selection(at: 50)
        #expect(end.elapsed == 25)
        #expect(end.position == nil)
        #expect(end.speed == nil)
        #expect(abs(end.routeDistance - 9) < 0.001)
    }

    @Test func breaksAtAnOutageAndAtRecoveryAfterRejectedFixes() {
        let track = syntheticTrack([
            fix(1, metres: 0), fix(2, metres: 2),
            fix(9, metres: 10), fix(10, metres: 12),
            fix(10.5, metres: 30, accuracy: 100), fix(11, metres: 30, accuracy: 100),
            fix(11.5, metres: 30, accuracy: 100), fix(12, metres: 30, accuracy: 100),
            fix(12.5, metres: 30, accuracy: 100),
            fix(13, metres: 100), fix(14, metres: 102),
        ])
        let replay = SessionReplay(track: track)
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)
        #expect(timeline.points.map(\.routeSegment) == [0, 0, 1, 1, 2, 2])

        let outage = timeline.selection(at: 5)
        #expect(outage.position == nil)
        #expect(outage.speed == nil)
        #expect(abs(outage.routeDistance - 2) < 0.001)
        let recovery = timeline.selection(at: 11)
        #expect(recovery.position == nil)
        #expect(recovery.speed == nil)
        #expect(abs(recovery.routeDistance - 4) < 0.001)
        #expect(timeline.selection(at: 13).position != nil)
        #expect(abs(timeline.selection(at: 14).routeDistance - 6) < 0.001)
        #expect(abs(replay.metrics.distance - 14) < 0.001)
    }

    @Test func pauseOnlyChangesTheSummaryDistance() {
        var track = syntheticTrack((0...6).map { fix(Double($0), metres: Double($0) * 2) })
        track.events += [SessionEvent(t: 1, type: .pause), SessionEvent(t: 4, type: .resume)]
        let replay = SessionReplay(track: track)
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)

        #expect(abs(replay.metrics.distance - 4) < 0.001)
        #expect(abs(timeline.selection(at: 6).routeDistance - 12) < 0.001)
    }

    @Test func winningSpeedWindowKeepsItsDopplerCurveAcrossARouteGap() throws {
        let track = syntheticTrack([0.0, 6, 12].map { fix($0, metres: $0 * 8, speed: 8) })
        let replay = SessionReplay(track: track)
        let window = try #require(replay.metrics.maxSpeed10sRange)
        #expect(window == 2...12)
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)
        #expect(timeline.selection(at: 2).speed == nil)
        #expect(timeline.selection(at: 2, speedWindow: window).position == nil)
        #expect(timeline.selection(at: 2, speedWindow: window).speed == 8)
        #expect(timeline.selection(at: 9, speedWindow: window).speed == 8)
        #expect(timeline.speedCurve(in: window).map(\.elapsed) == [2, 6, 12])
        #expect(timeline.speedCurve(in: window).map(\.speed) == [8, 8, 8])
    }

    @Test func preStartFixStaysSelectableAtTheExactWindowStart() throws {
        let track = syntheticTrack([-1.0, 0, 1].map { fix($0, metres: $0 + 1, speed: 6) })
        let replay = SessionReplay(track: track)
        let window = try #require(replay.metrics.maxSpeed2sRange)
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)
        #expect(window == -1...1)
        #expect(timeline.start == -1)
        #expect(timeline.selection(at: window.lowerBound).elapsed == -1)
        #expect(timeline.selection(at: window.lowerBound).speed == 6)
    }

    @Test func handlesEmptyAndSingleFixTracks() {
        for fixes in [[], [fix(10, metres: 0, speed: -1)]] {
            let track = syntheticTrack(fixes)
            let timeline = SessionReplayTimeline(replay: SessionReplay(track: track), recordedFixes: track.gps)
            #expect(timeline.selection(at: -1).elapsed == 0)
            #expect(timeline.selection(at: 10).speed == nil)
            #expect((timeline.selection(at: 10).position != nil) == !fixes.isEmpty)
            #expect(timeline.selection(at: 11).position == nil)
            #expect(timeline.selection(at: 25).routeDistance == 0)
        }
    }

    private func syntheticTrack(_ fixes: [GPSFix]) -> Track {
        Track(
            sessionId: UUID(), sport: .sailing, startedAt: Date(timeIntervalSince1970: 0), gps: fixes,
            hr: [HRSample(t: 5, bpm: 100)], events: [SessionEvent(t: 25, type: .stop)])
    }

    private func fix(_ time: Double, metres: Double, speed: Double? = 2, accuracy: Double = 5) -> GPSFix {
        let position = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: metres)
        return GPSFix(
            t: time, latitude: position.lat, longitude: position.lon, horizontalAccuracy: accuracy, speed: speed)
    }
}
