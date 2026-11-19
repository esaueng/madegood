/// A post-session course-over-ground estimate of a tack or gybe.
public struct SailingManeuver: Sendable, Hashable {
    /// The estimated wind-axis crossing time and the standard tack or gybe event data.
    public let event: SessionEvent
    /// Observed approach and departure fix times on the displayed session clock.
    public let range: ClosedRange<Double>
}

extension SailingManeuver {
    /// Approach-to-departure time, s.
    public var duration: Double { range.upperBound - range.lowerBound }
    /// Lowest Doppler speed in the turn below the approach speed, percent.
    public var speedLossPercent: Double? { number("speedLossPct") }
    /// Course change between the approach and departure legs, degrees (always positive).
    public var turnAngle: Double? { number("angleDeg") }

    private func number(_ key: String) -> Double? {
        if case .number(let value)? = event.data?[key] { return value }
        return nil
    }
}

/// One usable sailing fix: session time, Doppler speed (m/s) and reported course over
/// ground (degrees true).
struct SailingObservation: Sendable, Hashable {
    let t: Double
    let speed: Double
    let course: Double
}

extension SessionSelection {
    /// Detect sailing maneuvers on this selection's clock, including after trimming.
    /// Supply a session-wide wind-from direction in degrees true (0...360).
    /// Missing or invalid wind yields no events. Results are in chronological order.
    public func sailingManeuvers(windFromDegreesTrue wind: Double?) -> [SailingManeuver] {
        guard track.sport == .sailing, let wind, (0...360).contains(wind) else { return [] }
        return SailingManeuverDetector.detect(in: sailingObservationRuns(), windFrom: wind)
    }

    /// Fixes usable for sailing analysis, split into runs of uninterrupted evidence.
    /// Pauses, retained-span cuts, GPS gaps and anchors, a missing or unreliable course
    /// (including on a rejected fix) and speeds too low for a course all end a run.
    func sailingObservationRuns() -> [[SailingObservation]] {
        guard track.sport == .sailing else { return [] }
        let timeline = SessionReplayTimeline(replay: replay, recordedFixes: track.gps, endTime: duration)
        var unreliableCourses = track.gps.lazy.filter {
            $0.t.isFinite && !SailingManeuverDetector.reliableCourseAccuracy($0.courseAccuracy)
        }.makeIterator()
        var unreliableCourse = unreliableCourses.next()
        var transitions = replay.events.lazy.filter {
            $0.t.isFinite && ($0.type == .start || $0.type == .pause || $0.type == .resume)
        }.makeIterator()
        var transition = transitions.next()
        var runs: [[SailingObservation]] = []
        var run: [SailingObservation] = []
        func finishRun() {
            if !run.isEmpty { runs.append(run) }
            run.removeAll(keepingCapacity: true)
        }
        for (index, (span, range)) in zip(replay.fixSpans, replayRanges).enumerated() {
            // The selection supplies the original manual pause state at each span start.
            // Any previous auto-pause state ends at the cut.
            while index > 0, let event = transition, event.t < range.lowerBound {
                transition = transitions.next()
            }
            var paused = false
            var routeSegment: Int?
            for (fix, point) in zip(span, timeline.points[span.indices]) {
                // A discarded GPS fix can still indicate that course was unreliable
                // between otherwise accepted positions.
                while let uncertain = unreliableCourse, uncertain.t <= fix.t {
                    finishRun()
                    unreliableCourse = unreliableCourses.next()
                }
                if point.routeSegment != routeSegment {
                    finishRun()
                    routeSegment = point.routeSegment
                }
                while let event = transition, event.t <= fix.t {
                    finishRun()
                    paused = event.type == .pause
                    transition = transitions.next()
                }
                guard !paused, fix.t >= 0, fix.t <= duration,
                    let course = fix.course, (0...360).contains(course),
                    SailingManeuverDetector.reliableCourseAccuracy(fix.courseAccuracy),
                    let speed = point.speed, speed >= SailingManeuverDetector.minimumCourseSpeed
                else {
                    finishRun()
                    continue
                }
                run.append(SailingObservation(t: fix.t, speed: speed, course: course))
            }
            finishRun()
        }
        return runs
    }
}

struct SailingManeuverDetector {
    // Use the same minimum speed for trustworthy course as the live GPS filter.
    static let minimumCourseSpeed = GPSFilter.Config().minSpeedForCourse
    static let maximumTurnDuration = 20.0
    static let stableLegDuration = 3.0
    static let maximumLegSpread = 12.0
    static let axisProximity = 20.0
    static let maximumCourseStep = 45.0
    static let maximumCounterturn = 20.0
    static let minimumSpeedDipFraction = 0.10

    static func reliableCourseAccuracy(_ accuracy: Double?) -> Bool {
        accuracy.map { (0...axisProximity).contains($0) } ?? true
    }

    private struct Observation {
        let t: Double
        let speed: Double
        var course: Double
    }

    private var run: [Observation] = []
    private(set) var maneuvers: [SailingManeuver] = []

    /// Maneuvers in runs of observations, against a wind-from direction in degrees true.
    static func detect(in runs: [[SailingObservation]], windFrom wind: Double) -> [SailingManeuver] {
        var detector = SailingManeuverDetector()
        for run in runs {
            for observation in run {
                detector.append(
                    t: observation.t, speed: observation.speed, courseRelativeToWind: observation.course - wind)
            }
            detector.finishRun()
        }
        return detector.maneuvers
    }

    mutating func append(t: Double, speed: Double, courseRelativeToWind: Double) {
        let course =
            run.last.map {
                $0.course + GPSFilter.signedDifference(from: $0.course, to: courseRelativeToWind)
            } ?? courseRelativeToWind
        run.append(Observation(t: t, speed: speed, course: course))
    }

    mutating func finishRun() {
        defer { run.removeAll(keepingCapacity: true) }
        guard run.count >= 6 else { return }
        // A centered median on unwrapped courses removes single-fix spikes without
        // delaying a steady turn or averaging across north or the downwind axis.
        var smoothed = run
        for i in 1..<(run.count - 1) {
            let (a, b, c) = (run[i - 1].course, run[i].course, run[i + 1].course)
            smoothed[i].course = max(min(a, b), min(max(a, b), c))
        }
        for i in 1..<smoothed.count {
            guard let maneuver = Self.maneuver(in: smoothed, crossingAt: i),
                maneuvers.last.map({ $0.range.upperBound <= maneuver.range.lowerBound }) ?? true
            else { continue }
            maneuvers.append(maneuver)
        }
    }

    private static func maneuver(in fixes: [Observation], crossingAt right: Int) -> SailingManeuver? {
        let before = fixes[right - 1]
        let after = fixes[right]
        let beforeHalf = (before.course / 180).rounded(.down)
        let afterHalf = (after.course / 180).rounded(.down)
        guard beforeHalf != afterHalf else { return nil }

        let axis = max(beforeHalf, afterHalf) * 180
        let step = after.course - before.course
        guard abs(step) <= maximumCourseStep,
            min(abs(before.course - axis), abs(after.course - axis)) <= axisProximity
        else { return nil }
        let crossing = before.t + (axis - before.course) / step * (after.t - before.t)

        let approach = stride(from: right - 1, through: 0, by: -1)
            .prefix { crossing - fixes[$0].t < maximumTurnDuration }
            .first { stableLeg(in: fixes, at: $0, direction: -1) != nil }
        let departure = (right..<fixes.count)
            .prefix { fixes[$0].t - crossing < maximumTurnDuration }
            .first { stableLeg(in: fixes, at: $0, direction: 1) != nil }
        guard let approach, let departure else { return nil }

        let start = fixes[approach]
        let end = fixes[departure]
        let turn = end.course - start.course
        guard end.t - start.t <= maximumTurnDuration,
            abs(turn) > 60, abs(turn) < 180,
            (start.course - axis) * (end.course - axis) < 0
        else { return nil }

        var counterturn = 0.0
        var minimumSpeed = min(start.speed, end.speed)
        for i in (approach + 1)...departure {
            let delta = fixes[i].course - fixes[i - 1].course
            guard abs(delta) <= maximumCourseStep, abs(fixes[i].course - axis) < 180 else { return nil }
            counterturn += max(0, turn > 0 ? -delta : delta)
            minimumSpeed = min(minimumSpeed, fixes[i].speed)
        }
        guard counterturn <= maximumCounterturn,
            let legBefore = stableLeg(in: fixes, at: approach, direction: -1),
            let legAfter = stableLeg(in: fixes, at: departure, direction: 1),
            minimumSpeed <= min(legBefore.speed, legAfter.speed) * (1 - minimumSpeedDipFraction)
        else { return nil }
        let speedBefore = legBefore.speed

        let type: EventType = axis.truncatingRemainder(dividingBy: 360) == 0 ? .tack : .gybe
        let event = SessionEvent(
            t: crossing, type: type,
            data: [
                "durationS": .number(end.t - start.t),
                "speedLossPct": .number((1 - minimumSpeed / speedBefore) * 100),
                // Between the legs' mean courses: the edge fixes can already be turning.
                "angleDeg": .number(abs(legAfter.course - legBefore.course)),
            ])
        return SailingManeuver(event: event, range: start.t...end.t)
    }

    /// Mean Doppler speed and (unwrapped) course of a sustained course leading into or out
    /// of a turn. Require at least three fixes spanning 3–5 seconds within a 12° course band.
    private static func stableLeg(in fixes: [Observation], at start: Int, direction: Int)
        -> (speed: Double, course: Double)?
    {
        let anchor = fixes[start]
        var low = anchor.course
        var high = anchor.course
        var speedSum = anchor.speed
        var courseSum = anchor.course
        var count = 1
        var index = start + direction
        while fixes.indices.contains(index) {
            let sample = fixes[index]
            let span = abs(sample.t - anchor.t)
            guard span <= 5 else { break }
            low = min(low, sample.course)
            high = max(high, sample.course)
            guard high - low <= maximumLegSpread else { break }
            speedSum += sample.speed
            courseSum += sample.course
            count += 1
            if count >= 3, span >= stableLegDuration {
                return (speedSum / Double(count), courseSum / Double(count))
            }
            index += direction
        }
        return nil
    }
}
