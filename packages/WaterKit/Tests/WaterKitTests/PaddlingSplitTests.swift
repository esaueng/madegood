import Foundation
import Testing

@testable import WaterKit

@Suite struct PaddlingSplitTests {
    @Test func kilometreCrossingsAreSelectableAndIndependentOfWorkoutLaps() throws {
        let track = track(
            sport: .kayak, fixes: steadyFixes(0...700, metresPerSecond: 3),
            events: [SessionEvent(t: 101.5, type: .lap), SessionEvent(t: 710, type: .stop)])
        var profile = SportProfile.standard(for: .kayak)
        profile.autoLapDistance = 650
        let replay = SessionReplay(track: track, profile: profile)
        let splits = replay.paddlingSplits
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps)

        #expect(replay.metrics.laps.map(\.end) == [101.5, 318, 535])
        #expect(replay.metrics.laps.map(\.isAuto) == [false, true, true])
        #expect(splits.map(\.index) == [1, 2, 3])
        #expect(splits.map(\.isComplete) == [true, true, false])
        let first = try #require(splits.first)
        let second = try #require(splits.dropFirst().first)
        let partial = try #require(splits.last)
        #expect(first.elapsedRange.lowerBound == 0)
        #expect(abs(first.elapsedRange.upperBound - 1000.0 / 3) < 1e-6)
        #expect(abs(second.elapsedRange.upperBound - 2000.0 / 3) < 1e-6)
        #expect(first.elapsedRange.upperBound == second.elapsedRange.lowerBound)
        #expect(second.elapsedRange.upperBound == partial.elapsedRange.lowerBound)
        #expect(partial.elapsedRange.upperBound == 700)
        #expect(abs(partial.distance - 100) < 1e-6)
        #expect(abs(splits.reduce(0) { $0 + $1.movingTime } - replay.metrics.movingTime) < 1e-6)
        for split in splits {
            #expect(split.movingRanges == [split.elapsedRange])
            #expect(abs(split.averageSpeed - 3) < 1e-6)
            let selection = timeline.selection(at: split.elapsedRange.upperBound)
            #expect(selection.elapsed == split.elapsedRange.upperBound)
            #expect(selection.position != nil)
            #expect(selection.speed == 4)  // The replay cursor still shows measured Doppler speed.
            #expect(abs(selection.routeDistance - min(Double(split.index) * 1000, 2100)) < 1e-6)
        }
    }

    @Test func manualPauseKeepsSeparateSpansAndCreditsOnlyObservedMovingTime() throws {
        let replay = SessionReplay(
            track: track(
                sport: .canoe, fixes: steadyFixes(0...550),
                events: [SessionEvent(t: 10.5, type: .pause), SessionEvent(t: 20.5, type: .resume)]))
        let full = try #require(replay.paddlingSplits.first)
        let partial = try #require(replay.paddlingSplits.last)
        #expect(replay.paddlingSplits.count == 2)
        #expect(full.isComplete)
        #expect(abs(full.elapsedRange.upperBound - 511) < 1e-6)
        #expect(full.movingRanges == [0...10, 21...full.elapsedRange.upperBound])
        #expect(abs(full.movingTime - 500) < 1e-6)
        #expect(abs(partial.distance - 78) < 1e-6)
        #expect(partial.movingRanges == [full.elapsedRange.upperBound...550])
    }

    @Test func autoPauseRespectsClosedLapsAndDiscardsUnconfirmedResume() throws {
        let fixes = (0...22).map { second in
            let speed = second < 5 || second == 10 || second >= 13 ? 2.0 : 0.2
            return fix(Double(second), metres: Double(second) * 2, speed: speed)
        }
        var profile = SportProfile.standard(for: .sup)
        profile.autoPause.pauseAfter = 4
        let replay = SessionReplay(
            track: track(
                sport: .sup, fixes: fixes,
                events: [SessionEvent(t: 6.5, type: .lap), SessionEvent(t: 20, type: .pause, data: ["auto": true])]),
            profile: profile)
        let split = try #require(replay.paddlingSplits.first)

        #expect(replay.metrics.laps.first?.end == 6.5)
        #expect(replay.events.filter { $0.type == .pause || $0.type == .resume }.map(\.t) == [6.5, 12])
        #expect(split.elapsedRange == 0...22)
        #expect(split.movingRanges == [0...6, 12...22])
        #expect(split.movingTime == 16)
        #expect(abs(split.distance - 32) < 1e-6)
        #expect(split.movingTime == replay.metrics.movingTime)
        #expect(abs(split.distance - replay.metrics.distance) < 1e-6)
    }

    @Test func outagesAndReanchorsNeverEarnDistanceOrTime() throws {
        let rejected = [2.0, 2.2, 2.4, 2.6, 2.8].map { fix($0, metres: 200, accuracy: 100) }
        let fixes =
            [fix(0, metres: 0), fix(1, metres: 2)] + rejected + [
                fix(3, metres: 40), fix(4, metres: 42),
                fix(10, metres: 54), fix(11, metres: 56),
                fix(50, metres: 200), fix(55, metres: 210),
            ]
        let replay = SessionReplay(track: track(sport: .kayak, fixes: fixes))
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: fixes)
        let split = try #require(replay.paddlingSplits.first)

        #expect(replay.metrics.rejectedFixes == 5)
        #expect(replay.metrics.movingTime == 14)
        #expect(split.elapsedRange == 0...55)
        #expect(split.movingRanges == [0...1, 3...4, 10...11, 50...55])
        #expect(split.movingTime == 8)
        #expect(abs(split.distance - 16) < 1e-6)
        for time in [2.0, 7, 20] {
            #expect(timeline.selection(at: time).position == nil)
            #expect(!split.movingRanges.contains { $0.contains(time) })
        }
    }

    @Test func trimRebasesSplitBoundsAndRetainsTheSelectedProfile() throws {
        var meta = RawSessionReaderTests.meta(endedAt: nil)
        meta.sport = .sup
        let raw = RawSession(
            meta: meta, gps: (0...20).map { fix(Double($0), metres: Double($0) * 0.2, speed: 0.2) })
        let trim = try SessionTrim(start: 4.5, end: 19.5)
        var profile = SportProfile.standard(for: .sup)
        profile.autoPause.enabled = false
        let selection = try SessionSelection(session: raw, trim: trim, profile: profile)
        let split = try #require(selection.replay.paddlingSplits.first)

        #expect(split.elapsedRange == 0.5...14.5)
        #expect(split.movingRanges == [split.elapsedRange])
        #expect(split.movingTime == 14)
        #expect(abs(split.distance - 2.8) < 1e-6)
        #expect(!split.isComplete)
    }

    @Test func exactKilometreHasNoPhantomPartial() throws {
        let replay = SessionReplay(track: track(sport: .kayak, fixes: steadyFixes(0...500)))
        let split = try #require(replay.paddlingSplits.first)
        #expect(replay.paddlingSplits.count == 1)
        #expect(split.isComplete)
        #expect(split.distance == 1000)
        #expect(abs(split.elapsedRange.upperBound - 500) < 1e-6)
    }

    @Test func shortMiddleCutKeepsOneSplitWithSeparateMovingRanges() throws {
        var meta = RawSessionReaderTests.meta(endedAt: nil)
        meta.sport = .kayak
        let raw = RawSession(meta: meta, gps: steadyFixes(0...520))
        let trim = try SessionTrim(start: 10, end: 520, removing: [200...202])
        let selection = try SessionSelection(session: raw, trim: trim)
        let timeline = SessionReplayTimeline(replay: selection.replay, recordedFixes: selection.track.gps)
        let split = try #require(selection.replay.paddlingSplits.first)

        #expect(selection.replay.removedIntervals == [190...192])
        #expect(split.isComplete)
        #expect(abs(split.elapsedRange.upperBound - 502) < 1e-6)
        #expect(split.movingRanges == [0...190, 192...split.elapsedRange.upperBound])
        #expect(abs(split.movingTime - 500) < 1e-6)
        #expect(timeline.selection(at: 191).position == nil)
        #expect(timeline.selection(at: 190).routeDistance == timeline.selection(at: 192).routeDistance)
        #expect(abs(timeline.selection(at: split.elapsedRange.upperBound).routeDistance - 1000) < 1e-6)
    }

    @Test func emptyStationaryAndNonPaddlingSessionsHaveNoSplits() {
        let empty = SessionReplay(track: track(sport: .kayak, fixes: []))
        let oneFix = SessionReplay(track: track(sport: .kayak, fixes: steadyFixes(0...0)))
        let stationary = SessionReplay(
            track: track(sport: .kayak, fixes: (0...20).map { fix(Double($0), metres: 0, speed: 0) }))
        let sailing = SessionReplay(track: track(sport: .sailing, fixes: steadyFixes(0...10)))
        #expect(empty.paddlingSplits.isEmpty)
        #expect(oneFix.paddlingSplits.isEmpty)
        #expect(stationary.paddlingSplits.isEmpty)
        #expect(sailing.paddlingSplits.isEmpty)
    }

    private func track(sport: Sport, fixes: [GPSFix], events: [SessionEvent] = []) -> Track {
        Track(sessionId: UUID(), sport: sport, startedAt: Date(timeIntervalSince1970: 0), gps: fixes, events: events)
    }

    private func steadyFixes(_ seconds: ClosedRange<Int>, metresPerSecond: Double = 2) -> [GPSFix] {
        seconds.map { fix(Double($0), metres: Double($0) * metresPerSecond, speed: 4) }
    }

    private func fix(_ time: Double, metres: Double, speed: Double = 2, accuracy: Double = 5) -> GPSFix {
        let position = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: metres)
        return GPSFix(
            t: time, latitude: position.lat, longitude: position.lon, horizontalAccuracy: accuracy, speed: speed)
    }
}
