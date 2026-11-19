import Foundation
import Testing

@testable import WaterKit

/// Wind estimate, VMG and live sailing against synthetic tracks with known answers
/// (docs/metrics.md, "Sailing wind and VMG"). PLAN §5 targets: ≥ 95 % of labelled
/// maneuvers, < 5 % false positives, wind within ±10°.
@Suite struct SailingWindTests {
    // MARK: Wind estimate

    @Test(arguments: [0.0, 30, 95, 182.5, 271, 355])
    func upwindBeatEstimatesWindWithinTenDegrees(wind: Double) throws {
        let course = SyntheticCourse.beat(windFrom: wind, legs: [70, 85, 60, 95, 75, 80, 65, 90])
        let selection = try SessionSelection(session: course.session())
        let estimate = try #require(selection.estimatedWind())
        #expect(abs(GPSFilter.signedDifference(from: wind, to: estimate.fromDegrees)) <= 10)
        #expect(!estimate.resolvedByPrior)
        #expect(abs(estimate.legAngle - 90) <= 10)
        #expect(estimate.axisConfidence > 0.6)

        let analysis = selection.sailingAnalysis()
        #expect(analysis.windSource == .estimate)
        expectMatches(analysis.maneuvers, labels: course.labels)
        #expect(analysis.tackCount == course.labels.count)
        #expect(analysis.gybeCount == 0)
    }

    @Test func unevenTacksAndCourseNoiseStayWithinTenDegrees() throws {
        // One tack sailed three times longer than the other, with ±6° course noise.
        let course = SyntheticCourse.beat(windFrom: 210, legs: [150, 50, 160, 45, 140, 55], noise: 6)
        let estimate = try #require(try SessionSelection(session: course.session()).estimatedWind())
        #expect(abs(GPSFilter.signedDifference(from: 210, to: estimate.fromDegrees)) <= 10)
    }

    @Test func downwindLegsNeedAPriorToResolveTheDirection() throws {
        // Gybing downwind at 140° true wind angle: legs 80° apart around the downwind axis.
        let course = SyntheticCourse.beat(windFrom: 20, legs: [80, 70, 90, 75], halfAngle: 140)
        let selection = try SessionSelection(session: course.session())

        let unresolved = try #require(selection.estimatedWind())
        // Without a prior the legs are taken as upwind: 180° off.
        #expect(abs(GPSFilter.signedDifference(from: 200, to: unresolved.fromDegrees)) <= 10)
        #expect(!unresolved.resolvedByPrior)

        // A forecast 30° off still picks the right side of the axis.
        let resolved = try #require(selection.estimatedWind(prior: 50))
        #expect(abs(GPSFilter.signedDifference(from: 20, to: resolved.fromDegrees)) <= 10)
        #expect(resolved.resolvedByPrior)
        #expect(abs(resolved.axisConfidence - unresolved.axisConfidence) < 1e-9)

        let analysis = selection.sailingAnalysis(windPrior: 50)
        expectMatches(analysis.maneuvers, labels: course.labels)
        #expect(analysis.gybeCount == course.labels.count)
        #expect(analysis.upwindVMG == nil)
        // Downwind VMG: 5 m/s at 140° true wind angle is 5 × cos 40° away from the wind.
        let downwind = try #require(analysis.downwindVMG)
        #expect(abs(downwind - 5 * cos(40 * Double.pi / 180)) < 0.2)
    }

    /// Review regression: candidates 000°/180° with a forecast of 089° picked 000° and
    /// 091° picked 180°, both "resolved". A cross-axis forecast now decides nothing.
    @Test func aCrossAxisPriorLeavesTheSideUnresolved() throws {
        let selection = try SessionSelection(session: SyntheticCourse.beat(windFrom: 0, legs: [90, 90, 90]).session())
        let plain = try #require(selection.estimatedWind())
        #expect(plain.side == .unresolved)
        for prior in [89.0, 91, 270, 61 + plain.fromDegrees] {
            let sideways = try #require(selection.estimatedWind(prior: prior))
            #expect(sideways.side == .priorInconclusive(GPSFilter.normalize(prior)), "prior \(prior)")
            #expect(sideways.fromDegrees == plain.fromDegrees)
            #expect(sideways.axisConfidence == plain.axisConfidence)
            #expect(!selection.sailingAnalysis(windPrior: prior).windResolved)
        }
        // Within 60° of a candidate, the forecast chooses it.
        #expect(try #require(selection.estimatedWind(prior: 59 + plain.fromDegrees)).side == .resolvedByPrior)
        let flipped = try #require(selection.estimatedWind(prior: 200))
        #expect(flipped.side == .resolvedByPrior)
        #expect(abs(GPSFilter.signedDifference(from: 180, to: flipped.fromDegrees)) <= 10)
    }

    /// Review regression: two steady legs gave ~100 % confidence while the side was
    /// unknown. The confidence rates the axis; the side is reported separately, and an
    /// unresolved analysis has side-independent VMG and angle.
    @Test func unresolvedDownwindSessionOnlyKnowsTheAxis() throws {
        // True wind 020°, gybing at 140°: courses 160° and 240°, estimate 200° without a prior.
        let course = SyntheticCourse.beat(windFrom: 20, legs: [80, 70, 90, 75], halfAngle: 140)
        let selection = try SessionSelection(session: course.session())
        let analysis = selection.sailingAnalysis()
        let estimate = try #require(analysis.estimate)
        #expect(estimate.side == .unresolved)
        #expect(!analysis.windResolved)
        #expect(estimate.axisConfidence > 0.9)
        #expect(estimate.axisUncertainty >= CourseHistogram.binWidth / 2)
        #expect(estimate.axisUncertainty < 6)
        #expect(analysis.maneuvers.count == course.labels.count)
        // |VMG| and the angle to the axis do not depend on the side.
        let resolved = selection.sailingAnalysis(windPrior: 20)
        #expect(resolved.windResolved)
        let axisVMG = try #require(analysis.axisVMG)
        #expect(abs(axisVMG - (resolved.axisVMG ?? 0)) < 1e-9)
        #expect(abs(axisVMG - 5 * cos(40 * Double.pi / 180)) < 0.2)
        #expect(abs((analysis.axisAngle ?? 0) - 40) < 3)
        #expect(selection.sailingAnalysis(windFromDegreesTrue: 20).windResolved)
    }

    @Test func noEstimateWithoutTwoLegs() throws {
        // Straight line, a single short tack, and reaches 180° apart.
        let straight = SyntheticCourse.beat(windFrom: 0, legs: [300])
        #expect(try SessionSelection(session: straight.session()).estimatedWind() == nil)
        let short = SyntheticCourse.beat(windFrom: 0, legs: [15, 15])
        #expect(try SessionSelection(session: short.session()).estimatedWind() == nil)
        let reaches = SyntheticCourse.beat(windFrom: 0, legs: [120, 120, 120], halfAngle: 90)
        #expect(try SessionSelection(session: reaches.session()).estimatedWind() == nil)

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = repository.appendingPathComponent("fixtures/sailing/synthetic-straight-line")
        let fixture = try SessionSelection(session: RawSessionReader.read(folder: folder, includeMotion: false))
        let analysis = fixture.sailingAnalysis()
        #expect(analysis.estimate == nil)
        #expect(analysis.windSource == .none)
        #expect(analysis.maneuvers.isEmpty)
    }

    @Test func histogramIgnoresInvalidInputAndWrapsAtNorth() {
        var histogram = CourseHistogram()
        histogram.add(course: .nan, seconds: 10)
        histogram.add(course: 10, seconds: -1)
        histogram.add(course: 10, seconds: .infinity)
        #expect(histogram.totalTime == 0)
        // Legs at 315° and 45° (through north) and at 355°±45° wrapped by a whole turn.
        histogram.add(course: 315 - 720, seconds: 100)
        histogram.add(course: 45 + 360, seconds: 100)
        let estimate = histogram.windEstimate()
        #expect(estimate.map { abs(GPSFilter.signedDifference(from: 0, to: $0.fromDegrees)) < 0.001 } == true)
        #expect(estimate?.legCourses.map { $0.rounded() } == [45, 315])
        #expect(estimate.map { abs($0.axisConfidence - 100.0 / 120) < 1e-9 } == true)
    }

    @Test func replayStatsReportTheSameWindAndManeuvers() throws {
        let course = SyntheticCourse.beat(windFrom: 30, legs: [70, 85, 60, 95])
        let stats = SessionStats(session: course.session())
        let sailing = try #require(stats.sailing)
        #expect(sailing.maneuvers == 3)
        #expect(abs(GPSFilter.signedDifference(from: 30, to: sailing.windAxis ?? 210)) <= 10)
        // Without a prior the report names the axis only.
        #expect(stats.textReport().contains("Sailing   3 tacks or gybes, wind axis "))
        #expect(stats.textReport().contains("side unknown"))
        #expect(SessionStats(session: course.session(sport: .kayak)).sailing == nil)
    }

    // MARK: VMG

    @Test func vmgAndTrueWindAngleByHand() {
        // Close-hauled on port: wind from 0°, sailing 045°.
        #expect(SailingVMG.trueWindAngle(course: 45, windFrom: 0) == -45)
        #expect(abs(SailingVMG.vmg(speed: 5, course: 45, windFrom: 0) - 5 * 0.5.squareRoot()) < 1e-12)
        // Starboard, across north: wind from 350°, sailing 300°.
        #expect(SailingVMG.trueWindAngle(course: 300, windFrom: 350) == 50)
        // Running: VMG is negative (away from the wind).
        #expect(abs(SailingVMG.vmg(speed: 4, course: 180, windFrom: 0) + 4) < 1e-12)
    }

    @Test func userWindDrivesVMGTackTotalsAndPointing() throws {
        // Hand-computed: 5 m/s at 45° true wind angle, so upwind VMG is 5 cos 45° = 3.54.
        let course = SyntheticCourse.beat(windFrom: 0, legs: [120, 80], noise: 0)
        let selection = try SessionSelection(session: course.session())
        let analysis = selection.sailingAnalysis(windFromDegreesTrue: 0)
        #expect(analysis.windSource == .user)
        #expect(analysis.windFrom == 0)
        let tack = try #require(analysis.maneuvers.first)
        #expect(analysis.maneuvers.count == 1)
        #expect(abs((tack.turnAngle ?? 0) - 90) < 0.001)
        #expect(abs((tack.speedLossPercent ?? 0) - 50) < 0.001)

        #expect(abs((analysis.upwindVMG ?? 0) - 5 * cos(Double.pi / 4)) < 0.001)
        #expect(abs((analysis.pointingAngle ?? 0) - 45) < 0.001)
        #expect(abs((analysis.axisVMG ?? 0) - 5 * cos(Double.pi / 4)) < 0.001)
        #expect(abs((analysis.axisAngle ?? 0) - 45) < 0.001)
        #expect(analysis.downwindVMG == nil)
        // The first leg (course 315°) has the wind on starboard. Intervals that touch the
        // turn's approach-to-departure range count toward neither tack.
        let starboardEnd = tack.range.lowerBound
        let portStart = tack.range.upperBound
        #expect(abs(analysis.starboard.time - starboardEnd) < 0.001)
        #expect(abs(analysis.starboard.distance - 5 * starboardEnd) < 0.001)
        #expect(abs(analysis.port.time - (course.duration - portStart)) < 0.001)

        // An invalid user wind falls back to the estimate.
        #expect(selection.sailingAnalysis(windFromDegreesTrue: 400).windSource == .estimate)
    }

    /// Review regression: with a gradual turn the legs' edge fixes are already turning
    /// (11.25° steps fit the 12° leg band), and an angle between them read 68° for 90°.
    @Test func turnAngleUsesTheLegsMeanCourses() throws {
        let course = SyntheticCourse.beat(windFrom: 0, legs: [90, 90], noise: 0, turn: 8)
        let tack = try #require(
            try SessionSelection(session: course.session()).sailingAnalysis(windFromDegreesTrue: 0).maneuvers.first)
        // Hand-computed: each leg's 3 s mean includes one fix 11.25° into the turn.
        #expect(abs((tack.turnAngle ?? 0) - (90 - 2 * 11.25 / 4)) < 0.001)
    }

    @Test func otherSportsHaveNoSailingAnalysis() throws {
        let course = SyntheticCourse.beat(windFrom: 0, legs: [90, 90, 90])
        let kayak = try SessionSelection(session: course.session(sport: .kayak))
        let analysis = kayak.sailingAnalysis(windFromDegreesTrue: 0)
        #expect(analysis.maneuvers.isEmpty)
        #expect(analysis.estimate == nil)
        #expect(analysis.upwindVMG == nil)
    }

    // MARK: Live

    @Test func liveEngineEstimatesWindAndCountsTheSameManeuvers() throws {
        let course = SyntheticCourse.beat(windFrom: 30, legs: [70, 85, 60, 95, 75, 80])
        var engine = SessionEngine(sport: .sailing)
        engine.ingest(.event(SessionEvent(t: 0, type: .start)))
        var firstEstimate: Double?
        for fix in course.fixes {
            engine.ingest(.gps(fix))
            if firstEstimate == nil, engine.snapshot.sailing?.wind != nil { firstEstimate = fix.t }
        }
        let live = try #require(engine.snapshot.sailing)
        let wind = try #require(live.wind)
        #expect(abs(GPSFilter.signedDifference(from: 30, to: wind.fromDegrees)) <= 10)
        // Live, the estimate appears after the first tack once both legs have 20 s.
        #expect((firstEstimate ?? .infinity) < course.labels[0].t + 40)

        let post = try SessionSelection(session: course.session()).sailingAnalysis()
        #expect(live.maneuverCount == post.maneuvers.count)
        #expect(live.tacks == course.labels.count)

        // VMG from the current speed and smoothed course.
        let snapshot = engine.snapshot
        let angle = try #require(live.trueWindAngle)
        let vmg = try #require(live.vmg)
        #expect(abs(vmg - (snapshot.speed ?? 0) * cos(angle * .pi / 180)) < 1e-9)
        #expect(abs(abs(angle) - 45) < 10)

        #expect(SessionEngine(sport: .kayak).snapshot.sailing == nil)
        #expect(SessionEngine(sport: .sailing).snapshot.sailing == LiveSailing())
    }

    @Test func livePauseBreaksManeuverEvidence() {
        // A manual pause across the only tack: the turn is not joined across it.
        let course = SyntheticCourse.beat(windFrom: 0, legs: [90, 90], noise: 0)
        let turn = course.labels[0].t
        var engine = SessionEngine(sport: .sailing)
        engine.ingest(.event(SessionEvent(t: 0, type: .start)))
        for fix in course.fixes {
            if fix.t == turn - 2 { engine.ingest(.event(SessionEvent(t: fix.t, type: .pause))) }
            if fix.t == turn + 2 { engine.ingest(.event(SessionEvent(t: fix.t, type: .resume))) }
            engine.ingest(.gps(fix))
        }
        #expect(engine.snapshot.sailing?.wind != nil)
        #expect(engine.snapshot.sailing?.maneuverCount == 0)
    }

    /// Review regression: a tack whose departure leg settled after the last periodic
    /// refresh was missing from the count at the end of the session.
    @Test func stopRunsAFinalRefresh() throws {
        // Refreshes run every 10 s from t = 0. The second tack ends at 191 s; its departure
        // leg needs fixes to 195 s, after the refresh at 190 s, and the session stops at 199 s.
        let course = SyntheticCourse.beat(windFrom: 0, legs: [90, 90, 8], noise: 0)
        let lastTack = try #require(course.labels.last)
        var engine = SessionEngine(sport: .sailing)
        engine.ingest(.event(SessionEvent(t: 0, type: .start)))
        for fix in course.fixes { engine.ingest(.gps(fix)) }
        let end = try #require(course.fixes.last).t
        #expect(end == 199)
        #expect(lastTack.t == 189)
        let before = try #require(engine.snapshot.sailing).maneuverCount
        engine.ingest(.event(SessionEvent(t: end + 0.5, type: .stop)))
        let after = try #require(engine.snapshot.sailing).maneuverCount
        let post = try SessionSelection(session: course.session()).sailingAnalysis().maneuvers.count
        #expect(post == 2)
        #expect(after == post)
        #expect(before < after)
    }

    /// Review regression: refreshes rescanned the whole history every 10 s (quadratic,
    /// ~41 M visits for 8 h). Live is now incremental and replay a single pass.
    @Test func eightHourSessionStaysFastAndAgrees() throws {
        // 8 h at 1 Hz: tacks every ~2 minutes.
        let pattern: [Double] = [110, 125, 115, 130]
        let legs: [Double] = (0..<60).flatMap { _ in pattern }
        let course = SyntheticCourse.beat(windFrom: 75, legs: legs)
        #expect(course.duration > 8 * 3600)
        let clock = ContinuousClock()
        var engine = SessionEngine(sport: .sailing)
        let live = clock.measure {
            engine.ingest(.event(SessionEvent(t: 0, type: .start)))
            for fix in course.fixes { engine.ingest(.gps(fix)) }
            engine.ingest(.event(SessionEvent(t: course.duration + 1, type: .stop)))
        }
        var analysis: SailingAnalysis?
        let post = try clock.measure {
            analysis = try SessionSelection(session: course.session()).sailingAnalysis()
        }
        // Generous for debug builds on CI; the quadratic version took far longer.
        #expect(live < .seconds(10), "live \(live)")
        #expect(post < .seconds(10), "post \(post)")
        let count = try #require(engine.snapshot.sailing).maneuverCount
        #expect(count == analysis?.maneuvers.count)
        #expect(count == course.labels.count)
    }

    /// Re-check regression: the app stored the engine and fed it through a copy
    /// (copy out, mutate, store back), so each fix copied the growing sailing history.
    /// `Optional<SessionEngine>.update` is what the recorder uses: over 8 h it never
    /// copies the history, where the old pattern copied it on every fix.
    @Test func recorderMutationPatternStaysLinear() {
        final class Recorder {
            var engine: SessionEngine? = SessionEngine(sport: .sailing)
            var metrics: LiveMetrics?
            let inPlace: Bool
            init(inPlace: Bool) { self.inPlace = inPlace }
            func ingest(_ sample: Sample) {
                if inPlace {
                    metrics = engine.update { engine in
                        engine.ingest(sample)
                        return engine.snapshot
                    }
                } else {
                    // The old pattern, for contrast.
                    guard var copy = engine else { return }
                    copy.ingest(sample)
                    engine = copy
                    metrics = copy.snapshot
                }
            }
        }
        let pattern: [Double] = [110, 125, 115, 130]
        let course = SyntheticCourse.beat(windFrom: 75, legs: (0..<60).flatMap { _ in pattern })
        let recorder = Recorder(inPlace: true)
        let elapsed = ContinuousClock().measure {
            recorder.ingest(.event(SessionEvent(t: 0, type: .start)))
            for fix in course.fixes { recorder.ingest(.gps(fix)) }
        }
        #expect(elapsed < .seconds(10), "recorder pattern \(elapsed)")
        #expect(recorder.engine?.sailingStorageCopies == 0)
        #expect(recorder.metrics?.sailing?.maneuverCount ?? 0 >= course.labels.count - 1)

        let old = Recorder(inPlace: false)
        old.ingest(.event(SessionEvent(t: 0, type: .start)))
        for fix in course.fixes.prefix(600) { old.ingest(.gps(fix)) }
        #expect(old.engine?.sailingStorageCopies ?? 0 > 500)
        var missing: SessionEngine?
        #expect(missing.update { $0.snapshot } == nil)
    }

    /// Re-check regression: with legs on 000°, 080° and 160°, the axes 040° and 120° are
    /// nearly equal and could alternate every refresh, each switch rescanning everything
    /// and removing or restoring turns. The shown axis needs a clear, lasting win, full
    /// rescans are capped, and live counts never fall.
    @Test func competingAxesDoNotThrashTheLiveTracker() {
        var tracker = SailingTracker()
        let legs: [Double] = [0, 80, 160, 80]
        var t = 0.0
        var counts: [Int] = []
        var axes: [Double] = []
        for repetition in 0..<30 {
            for (index, leg) in legs.enumerated() {
                let next = legs[(index + 1) % legs.count]
                for second in 0..<60 {
                    let jitter = Double((repetition * 7 + second * 13) % 7) - 3
                    tracker.ingest(t: t, speed: 5, course: GPSFilter.normalize(leg + jitter), courseAccuracy: nil)
                    t += 1
                }
                for step in 0..<6 {
                    let fraction = Double(step) / 6
                    let dip = 1 - 0.5 * (1 - abs(fraction * 2 - 1))
                    let course = leg + GPSFilter.signedDifference(from: leg, to: next) * fraction
                    tracker.ingest(t: t, speed: 5 * dip, course: GPSFilter.normalize(course), courseAccuracy: nil)
                    t += 1
                    counts.append(tracker.tacks + tracker.gybes)
                }
                if let wind = tracker.wind?.fromDegrees { axes.append(wind) }
            }
        }
        // Monotone live counts.
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
        // At most one full rescan per 5 minutes (plus the first).
        #expect(tracker.fullRescans <= Int(t / SailingTracker.minimumRescanInterval) + 1)
        // The shown axis switches rarely, not every leg.
        let switches = zip(axes, axes.dropFirst()).count {
            let d = abs(GPSFilter.signedDifference(from: $0, to: $1))
            return min(d, 180 - d) > SailingTracker.rescanWindChange
        }
        #expect(switches <= 4, "axis switched \(switches) times over \(axes.count) legs")
    }

    /// Re-check regression: a 6 s GPS outage inside a turn split post-session runs (the
    /// replay route breaks after 5 s) but not live runs, so the counts differed. Live
    /// now breaks its runs at the same gap.
    @Test func gpsOutageInsideATurnBreaksLiveAndPostAlike() throws {
        // A 16 s turn, so the course step across the 6 s gap (about 34°) is small enough
        // that only the gap rule, not the step limit, keeps the turn out.
        let full = SyntheticCourse.beat(windFrom: 0, legs: [90, 90, 90], noise: 0, turn: 16)
        let turn = full.labels[0].t
        var course = full
        course.fixes.removeAll { $0.t > turn - 3 && $0.t < turn + 3 }
        #expect(full.fixes.count - course.fixes.count == 5)
        #expect(try SessionSelection(session: full.session()).sailingAnalysis().maneuvers.count == 2)
        var engine = SessionEngine(sport: .sailing)
        engine.ingest(.event(SessionEvent(t: 0, type: .start)))
        for fix in course.fixes { engine.ingest(.gps(fix)) }
        engine.ingest(.event(SessionEvent(t: course.duration + 1, type: .stop)))
        let post = try SessionSelection(session: course.session()).sailingAnalysis().maneuvers
        let live = try #require(engine.snapshot.sailing).maneuverCount
        #expect(post.count == 1)
        #expect(live == post.count)
        #expect(post.allSatisfy { !$0.range.contains(turn) })
    }

    // MARK: Helpers

    private func expectMatches(_ maneuvers: [SailingManeuver], labels: [SessionEvent]) {
        var unmatched = maneuvers
        var matches = 0
        for label in labels {
            if let index = unmatched.firstIndex(where: {
                $0.event.type == label.type && abs($0.event.t - label.t) <= 2 && $0.range.contains(label.t)
            }) {
                unmatched.remove(at: index)
                matches += 1
            }
        }
        #expect(Double(matches) / Double(labels.count) >= 0.95)
        #expect(Double(unmatched.count) / Double(max(1, maneuvers.count)) < 0.05)
    }
}

/// A synthetic zig-zag: legs at ±`halfAngle` true wind angle joined by `turn` s turns through
/// the wind (or downwind axis) with a 50 % speed dip, 1 Hz fixes, deterministic noise.
struct SyntheticCourse {
    var fixes: [GPSFix] = []
    var labels: [SessionEvent] = []
    var duration = 0.0

    static func beat(
        windFrom wind: Double, legs: [Double], halfAngle: Double = 45, speed: Double = 5, noise: Double = 3,
        turn: Double = 6
    ) -> SyntheticCourse {
        var course = SyntheticCourse()
        var position = (lat: 10.0, lon: -30.0)
        var random: UInt64 = 0x2545_F491_4F6C_DD1D
        func jitter() -> Double {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(random >> 11) / Double(1 << 53) * 2 - 1) * noise
        }
        var t = 0.0
        // Starboard first: the wind on the right, so course = wind − angle.
        var side = -1.0
        let type: EventType = halfAngle < 90 ? .tack : .gybe
        for (index, leg) in legs.enumerated() {
            var segment: [(course: Double, speed: Double)] = Array(
                repeating: (wind + side * halfAngle, speed), count: Int(leg))
            if index < legs.count - 1 {
                let from = wind + side * halfAngle
                // Upwind turns go through the wind; downwind turns through the run.
                let to = halfAngle < 90 ? wind - side * halfAngle : wind - side * halfAngle + side * 360
                for step in 0..<Int(turn) {
                    let fraction = Double(step) / turn
                    let dip = 1 - 0.5 * (1 - abs(fraction * 2 - 1))
                    segment.append((from + (to - from) * fraction, speed * dip))
                }
                course.labels.append(SessionEvent(t: t + leg + turn / 2, type: type))
            }
            for (heading, v) in segment {
                let reported = GPSFilter.normalize(heading + jitter())
                course.fixes.append(
                    GPSFix(
                        t: t, latitude: position.lat, longitude: position.lon, horizontalAccuracy: 5, speed: v,
                        course: reported))
                position = Geo.destination(lat: position.lat, lon: position.lon, bearing: reported, distance: v)
                t += 1
            }
            side = -side
        }
        course.duration = t - 1
        return course
    }

    func session(sport: Sport = .sailing) -> RawSession {
        let start = 946_684_800.0
        let endTime = (fixes.last?.t ?? 0) + 1
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: sport, startedAt: start, endedAt: start + endTime,
            clock: RawFormat.ClockAnchor(unix: start, uptime: 1_000),
            device: RawFormat.Device(kind: "watch", model: "Synthetic", os: "watchOS"),
            app: RawFormat.App(version: "1.0", build: "test"))
        return RawSession(
            meta: meta, gps: fixes, events: [.init(t: 0, type: .start), .init(t: endTime, type: .stop)])
    }
}
