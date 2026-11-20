import Testing

@testable import WaterKit

@Suite struct WindsurfAnalysisTests {
    private func recording(_ samples: [(Double, Double?)]) -> RawSession {
        var course = SyntheticCourse()
        course.fixes = samples.map { time, speed in
            GPSFix(t: time, latitude: 0, longitude: 0, horizontalAccuracy: 3, speed: speed, course: 90)
        }
        return course.session(sport: .windsurfing)
    }

    @Test func planingInterpolatesCrossingsAndRejectsShortBursts() throws {
        // Deliberately stationary positions. Only the reported Doppler speeds matter.
        let session = recording(
            (0...14).map { time in
                (Double(time), (2...6).contains(time) ? 6 : (time == 10 ? 8 : 4))
            })
        let selection = try SessionSelection(session: session)
        let planing = try #require(selection.windsurfAnalysis()?.planing)
        #expect(planing.time == 5)  // 1.5–6.5 s; the isolated fast fix does not qualify.
        #expect(planing.observedTime == 14)
        #expect(planing.fraction == 5.0 / 14)

        var profile = SportProfile.standard(for: .windsurfing)
        profile.planingSpeedThreshold = 6.5
        let higher = try SessionSelection(session: session, profile: profile)
        #expect(higher.windsurfAnalysis()?.planing?.time == 0)
    }

    @Test func gapsMissingSpeedsAndManualPausesBreakRuns() throws {
        let samples = [0, 1, 2] + Array(9...20)
        var session = recording(samples.map { (Double($0), $0 == 11 ? nil : 7) })
        session.events += [.init(t: 14.5, type: .pause), .init(t: 16.5, type: .resume)]
        let selection = try SessionSelection(session: session)
        let planing = try #require(selection.windsurfAnalysis()?.planing)
        #expect(planing.observedTime == 8)
        #expect(planing.time == 3)
    }

    @Test func planingRespectsAutoPauseAndTrimCuts() throws {
        var profile = SportProfile.standard(for: .windsurfing)
        profile.autoPause.enabled = true
        let stopped = recording((0...32).map { (Double($0), (6...25).contains($0) ? 0 : 7) })
        let selection = try SessionSelection(session: stopped, profile: profile)
        let planing = try #require(selection.windsurfAnalysis()?.planing)
        #expect(planing.time > 10)
        #expect(planing.observedTime == selection.replay.metrics.movingTime)
        #expect(planing.observedTime < 20)

        let acrossCut = recording((0...8).map { (Double($0), 7) })
        let trim = try SessionTrim(start: 0, end: 8, removing: [2...6])
        let trimmed = try SessionSelection(session: acrossCut, trim: trim)
        let cut = try #require(trimmed.windsurfAnalysis()?.planing)
        #expect(cut.observedTime == 4)
        #expect(cut.time == 0)
    }

    @Test func noDopplerDataLeavesPlaningUnmeasured() throws {
        let selection = try SessionSelection(session: recording([(0, nil), (1, nil)]))
        #expect(selection.windsurfAnalysis()?.planing == nil)
        #expect(selection.windsurfAnalysis()?.estimatedGybeCount == nil)
    }

    @Test func broadReachingGybesReuseTheSailingTurnChecks() throws {
        // 160° between fast legs, through north. Too broad for sailing's wind estimate.
        var course = SyntheticCourse.beat(
            windFrom: 180, legs: [70, 85, 65, 70], halfAngle: 100, speed: 9, noise: 2, turn: 8)
        let session = course.session(sport: .windsurfing)
        let selection = try SessionSelection(session: session)
        #expect(selection.windsurfAnalysis()?.estimatedGybeCount == course.labels.count)

        let trim = try SessionTrim(start: 0, end: course.duration, removing: [65...85])
        let trimmed = try SessionSelection(session: session, trim: trim)
        #expect(trimmed.windsurfAnalysis()?.estimatedGybeCount == course.labels.count - 1)

        for index in course.fixes.indices { course.fixes[index].speed = 9 }
        let noDip = try SessionSelection(session: course.session(sport: .windsurfing))
        #expect(noDip.windsurfAnalysis()?.estimatedGybeCount == 0)
        let sailing = try SessionSelection(session: course.session())
        #expect(sailing.windsurfAnalysis() == nil)
        #expect(sailing.estimatedWind() == nil)
    }

    @Test func gybesFromAboveBeamCanTurnThroughTheLongerArc() throws {
        let course = SyntheticCourse.beat(
            windFrom: 0, legs: [70, 85, 65, 70], halfAngle: 80, speed: 9, noise: 2, turn: 10, gybing: true)
        let selection = try SessionSelection(session: course.session(sport: .windsurfing))
        #expect(selection.windsurfAnalysis()?.estimatedGybeCount == course.labels.count)

        var mixed = course
        let opposite = SyntheticCourse.beat(
            windFrom: 180, legs: [70, 85, 65, 70], halfAngle: 100, speed: 9, noise: 2, turn: 8)
        mixed.fixes += opposite.fixes.map {
            var fix = $0
            fix.t += course.duration + 60
            return fix
        }
        let ambiguous = try SessionSelection(session: mixed.session(sport: .windsurfing))
        #expect(ambiguous.windsurfAnalysis()?.estimatedGybeCount == nil)
    }
}
