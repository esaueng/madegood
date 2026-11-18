import Foundation
import Testing

@testable import WaterKit

@Suite struct SailingManeuverTests {
    @Test func labeledSailingTrack() throws {
        // A beat upwind, a bear-away on the same side of the wind, and two downwind legs.
        let gps = fixes([
            (10.25, 305, 5), (25.25, 305, 5), (29.25, 350, 2.5), (33.25, 395, 4.7),
            (48.25, 395, 4.7), (53.25, 350, 2.2), (58.25, 303, 5),
            (68.25, 303, 5), (75.25, 215, 5), (85.25, 215, 6),
            (90.25, 170, 4), (95.25, 125, 6.5), (115.25, 125, 6.5),
            (120.25, 170, 3.8), (125.25, 215, 6), (150.25, 215, 6),
        ])
        let labels: [SessionEvent] = [
            .init(t: 29.25, type: .tack), .init(t: 53.25, type: .tack),
            .init(t: 90.25, type: .gybe), .init(t: 120.25, type: .gybe),
        ]
        let selection = try SessionSelection(session: session(gps))
        let maneuvers = selection.sailingManeuvers(windFromDegreesTrue: 350)
        var unmatched = maneuvers
        var matches = 0
        for label in labels {
            if let index = unmatched.firstIndex(where: {
                $0.event.type == label.type && abs($0.event.t - label.t) <= 1 && $0.range.contains(label.t)
            }) {
                unmatched.remove(at: index)
                matches += 1
            }
        }
        #expect(Double(matches) / Double(labels.count) >= 0.95)
        #expect(Double(unmatched.count) / Double(max(1, maneuvers.count)) < 0.05)
        #expect(maneuvers.map(\.event.type) == labels.map(\.type))
    }

    @Test func replayUsesObservedBoundsAndCrossingOnTheTrimmedClock() throws {
        let recording = session(
            fixes([
                (5.5, 315, 5), (14.5, 315, 5), (17.5, 356, 2), (19.5, 378, 3), (21.5, 405, 5), (32.5, 405, 5),
            ]))
        let original = try SessionSelection(session: recording)
        let originalEvents = original.sailingManeuvers(windFromDegreesTrue: 0)
        let tack = try #require(originalEvents.first)
        #expect(originalEvents.count == 1)
        #expect(tack.event.type == .tack)
        #expect(abs(tack.event.t - (17.5 + 4.0 / 11)) < 0.000001)
        #expect(tack.range == 14.5...21.5)
        #expect(tack.event.data?["durationS"] == .number(7))
        let loss = try #require(tack.event.data?["speedLossPct"])
        #expect(loss == .number(60))
        #expect(original.sailingManeuvers(windFromDegreesTrue: 360) == originalEvents)
        let encoded = try TrackCodec.encodeJSON(original.track)
        _ = original.sailingManeuvers(windFromDegreesTrue: 0)
        #expect(try TrackCodec.encodeJSON(original.track) == encoded)

        let trimmed = try SessionSelection(session: recording, trim: SessionTrim(start: 10.25, end: 28))
        let trimmedTack = try #require(trimmed.sailingManeuvers(windFromDegreesTrue: 0).first)
        #expect(trimmedTack.range == 4.25...11.25)
        #expect(abs(trimmedTack.event.t - (tack.event.t - 10.25)) < 0.000001)
        let timeline = SessionReplayTimeline(
            replay: trimmed.replay, recordedFixes: trimmed.track.gps, endTime: trimmed.duration)
        #expect(timeline.selection(at: trimmedTack.event.t).position != nil)
        #expect(timeline.points.contains { $0.elapsed == trimmedTack.range.lowerBound })
        #expect(timeline.points.contains { $0.elapsed == trimmedTack.range.upperBound })
        let cutThroughTurn = try SessionSelection(session: recording, trim: SessionTrim(start: 18, end: 28))
        #expect(cutThroughTurn.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)
    }

    @Test func downwindCrossingWrapsAtNorthAndToleratesOneCourseSpike() throws {
        var gps = tackTrack
        // A single reported-course spike on the approach cannot manufacture a turn.
        gps[5].course = 40
        let selection = try SessionSelection(session: session(gps))
        let result = selection.sailingManeuvers(windFromDegreesTrue: 180)
        #expect(result.count == 1)
        #expect(result.first?.event.type == .gybe)
        #expect(result.first?.event.t == 16)
    }

    @Test func shortMiddleCutBreaksSailingDetectionAndPreservesAnIntactTurn() throws {
        let recording = session(tackTrack)
        let cutThroughTurn = try SessionSelection(
            session: recording, trim: SessionTrim(start: 0, end: 30, removing: [15...17]))
        #expect(cutThroughTurn.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)

        let cutBeforeTurn = try SessionSelection(
            session: recording, trim: SessionTrim(start: 1, end: 30, removing: [4...6]))
        let intact = try #require(cutBeforeTurn.sailingManeuvers(windFromDegreesTrue: 0).first)
        #expect(intact.range == 12...18)
        #expect(intact.event.t == 15)
        #expect(cutBeforeTurn.replayRanges[1].contains(intact.event.t))
    }

    @Test func requiresExplicitWindAndSailingSport() throws {
        let selection = try SessionSelection(session: session(tackTrack))
        for wind: Double? in [nil, .nan, .infinity, -.infinity, -1, 361, 90] {
            #expect(selection.sailingManeuvers(windFromDegreesTrue: wind).isEmpty)
        }
        let paddling = try SessionSelection(session: session(tackTrack, sport: .kayak))
        #expect(paddling.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)
    }

    @Test func rejectsTurnsAcrossGPSGapsAndRecoveryAnchors() throws {
        let outage = tackTrack.filter { !(13...19).contains($0.t) }
        let shortOutage = try SessionSelection(session: session(outage))
        #expect(shortOutage.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)

        var reanchored = tackTrack
        let rejected = (1...5).map { sample -> GPSFix in
            var badFix = reanchored[15]
            badFix.t += Double(sample) / 10
            badFix.horizontalAccuracy = 100
            return badFix
        }
        reanchored.insert(contentsOf: rejected, at: 16)
        let recovery = try SessionSelection(session: session(reanchored))
        #expect(recovery.replay.metrics.rejectedFixes == 5)
        #expect(recovery.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)

        var singleReject = tackTrack
        singleReject[5].horizontalAccuracy = 100
        let good = try SessionSelection(session: session(singleReject))
        #expect(good.replay.metrics.rejectedFixes == 1)
        #expect(good.sailingManeuvers(windFromDegreesTrue: 0).count == 1)
    }

    @Test func doesNotCrossPauseOrUseUnreliableCourse() throws {
        let paused = try SessionSelection(
            session: session(
                tackTrack,
                events: [
                    SessionEvent(t: 14.5, type: .pause), SessionEvent(t: 17.5, type: .resume),
                ]))
        #expect(paused.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)

        let preStart = tackTrack.map { fix in
            var fix = fix
            fix.t -= 18
            return fix
        }
        #expect(try SessionSelection(session: session(preStart)).sailingManeuvers(windFromDegreesTrue: 0).isEmpty)

        for missing in ["course", "speed", "stationary"] {
            var gps = tackTrack
            switch missing {
            case "course": gps[16].course = nil
            case "speed": gps[16].speed = nil
            default: gps[16].speed = 0.3
            }
            let selection = try SessionSelection(session: session(gps))
            #expect(selection.sailingManeuvers(windFromDegreesTrue: 0).isEmpty, "Unreliable \(missing)")
        }
    }

    @Test func rejectsNonManeuvers() throws {
        let scenarios: [(String, [Knot])] = [
            ("straight with speed dip", [(0, 45, 5), (12, 45, 5), (16, 45, 2), (20, 45, 5), (30, 45, 5)]),
            ("tack without a dip", [(0, 315, 5), (12, 315, 5), (20, 405, 5), (30, 405, 5)]),
            ("bear-away with a dip", [(0, 35, 5), (12, 35, 5), (16, 80, 2), (20, 125, 5), (30, 125, 5)]),
            ("60-degree turn", [(0, 330, 5), (12, 330, 5), (16, 360, 2), (20, 390, 5), (30, 390, 5)]),
            ("slow crossing", [(0, 315, 5), (12, 315, 5), (24, 360, 2), (36, 405, 5), (45, 405, 5)]),
            ("unobserved crossing", [(0, 315, 5), (15, 315, 5), (16, 405, 2), (20, 405, 5), (30, 405, 5)]),
            ("abandoned tack", [(0, 315, 5), (12, 315, 5), (16, 370, 2), (20, 315, 5), (30, 315, 5)]),
        ]
        for (name, knots) in scenarios {
            let selection = try SessionSelection(session: session(fixes(knots)))
            #expect(selection.sailingManeuvers(windFromDegreesTrue: 0).isEmpty, "Scenario: \(name)")
        }
    }

    @Test func straightLineRepositoryFixtureHasNoManeuvers() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = repository.appendingPathComponent("fixtures/sailing/synthetic-straight-line")
        let recording = try RawSessionReader.read(folder: folder, includeMotion: false)
        let selection = try SessionSelection(session: recording)
        #expect(selection.replay.fixes.count > 250)
        #expect(selection.sailingManeuvers(windFromDegreesTrue: 0).isEmpty)
    }

    private var tackTrack: [GPSFix] {
        fixes([(0, 315, 5), (12, 315, 5), (16, 360, 2), (20, 405, 5), (30, 405, 5)])
    }

    private typealias Knot = (t: Double, course: Double, speed: Double)

    /// Make a synthetic GPS track from linearly changing course and Doppler speed.
    private func fixes(_ knots: [Knot]) -> [GPSFix] {
        var position = (lat: 10.0, lon: -30.0)
        var result: [GPSFix] = []
        for (start, end) in zip(knots, knots.dropFirst()) {
            for t in stride(from: start.t, to: end.t, by: 1) {
                let fraction = (t - start.t) / (end.t - start.t)
                let course = GPSFilter.normalize(start.course + (end.course - start.course) * fraction)
                let speed = start.speed + (end.speed - start.speed) * fraction
                result.append(
                    GPSFix(
                        t: t, latitude: position.lat, longitude: position.lon,
                        horizontalAccuracy: 5, speed: speed, course: course))
                position = Geo.destination(lat: position.lat, lon: position.lon, bearing: course, distance: speed)
            }
        }
        return result
    }

    private func session(
        _ gps: [GPSFix], sport: Sport = .sailing, events: [SessionEvent] = []
    ) -> RawSession {
        let start = 946_684_800.0
        let endTime = (gps.last?.t ?? 0) + 1
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: sport, startedAt: start, endedAt: start + endTime,
            clock: RawFormat.ClockAnchor(unix: start, uptime: 1_000),
            device: RawFormat.Device(kind: "watch", model: "Synthetic", os: "watchOS"),
            app: RawFormat.App(version: "1.0", build: "test"))
        return RawSession(
            meta: meta, gps: gps, events: [.init(t: 0, type: .start)] + events + [.init(t: endTime, type: .stop)])
    }
}
