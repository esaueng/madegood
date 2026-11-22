import Foundation
import Testing

@testable import WaterKit

/// The detector must find the same wrist cycles at 50 Hz as at 100 Hz (docs/metrics.md
/// "Strokes"). A real 100 Hz kayak recording decimated to 50 Hz kept its stroke count, but
/// most cycles moved by about ±450 ms: the principal axis's sign is arbitrary, it decides
/// which lobe of the wrist cycle is the peak, and the first sign was carried through the
/// session. Any small change (sample rate, bin phase, start time) could pick the other one.
///
/// The bar is what the user sees: the stroke count, the rate and (canoe, SUP) the paddling
/// side. Where the stroke is nearly symmetric and the watch turns, which lobe is the stroke
/// is ambiguous, and the two rates can settle on lobes 0.5–1 s apart, so the turn tests
/// compare counts, rates and sides, not stroke times. Steady paddling, rests and gaps still
/// keep the same stroke times.
@Suite struct StrokeRateInvarianceTests {
    /// Every second sample from `phase` (0 or 1), as a 100 Hz recording would be at 50 Hz.
    static func decimated(_ motion: [MotionSample], phase: Int = 0) -> [MotionSample] {
        stride(from: phase, to: motion.count, by: 2).map { motion[$0] }
    }

    /// Pairs of samples averaged, as a sensor that filters before it decimates.
    static func pairAveraged(_ motion: [MotionSample]) -> [MotionSample] {
        stride(from: 0, to: motion.count - 1, by: 2).map { index in
            let a = motion[index]
            var b = motion[index + 1]
            b.userAcceleration = mean(a.userAcceleration, b.userAcceleration)
            b.rotationRate = mean(a.rotationRate, b.rotationRate)
            b.gravity = mean(a.gravity, b.gravity)
            return b
        }
    }

    static func mean(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: (a.z + b.z) / 2)
    }

    static func cycles(_ motion: [MotionSample], sport: Sport) -> [StrokeDetector.Cycle] {
        StrokeAnalysis.detect(motion: motion, sport: sport).cycles
    }

    /// Session detail's strokes over the whole stream: count, average rate and cycles.
    static func strokes(_ motion: [MotionSample], sport: Sport) -> (
        count: Int, rate: Double?, cycles: [StrokeDetector.Cycle]
    ) {
        let detection = StrokeAnalysis.detect(motion: motion, sport: sport)
        let analysis = StrokeAnalysis(detection: detection, sport: sport, distance: nil)
        return (analysis.strokeCount, analysis.averageStrokeRate, detection.cycles)
    }

    /// Cycles after `from` whose nearest cycle in `reference` (within `tolerance`) has the
    /// same side, and how many were compared.
    static func sideAgreement(
        _ cycles: [StrokeDetector.Cycle], _ reference: [StrokeDetector.Cycle], after from: Double,
        tolerance: Double
    ) -> (agree: Int, compared: Int) {
        var agree = 0
        var compared = 0
        for cycle in cycles where cycle.t > from {
            guard let match = reference.min(by: { abs($0.t - cycle.t) < abs($1.t - cycle.t) }),
                abs(match.t - cycle.t) <= tolerance
            else { continue }
            compared += 1
            if match.side == cycle.side { agree += 1 }
        }
        return (agree, compared)
    }

    /// Share of `times` within `tolerance` of a time in `reference` (both sorted).
    static func matched(_ times: [Double], in reference: [Double], tolerance: Double = 0.04) -> Double {
        guard !times.isEmpty else { return 0 }
        var next = 0
        var hits = 0
        for t in times {
            while next < reference.count - 1, reference[next + 1] <= t { next += 1 }
            let nearest = [next, next + 1].filter { $0 < reference.count }.map { abs(reference[$0] - t) }.min()
            if let nearest, nearest <= tolerance { hits += 1 }
        }
        return Double(hits) / Double(times.count)
    }

    /// Cycles at `other` agree with `reference` both ways, and the counts within 1 %. The
    /// other lobe is about 0.2 of a period away (0.4–0.5 s), so at least 99 % within 0.2 s
    /// means the same lobe. At least 93 % within 40 ms: the simulator's per-sample noise
    /// moves some peaks of its broad lobes by 40–160 ms when half the samples are averaged
    /// into each bin (the real kayak recording agrees for 98 % or more).
    func expectSameCycles(
        _ other: [StrokeDetector.Cycle], _ reference: [StrokeDetector.Cycle], _ comment: String,
        shares: (within40ms: Double, within200ms: Double) = (0.93, 0.99),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let a = reference.map(\.t)
        let b = other.map(\.t)
        for (tolerance, share) in [(0.04, shares.within40ms), (0.2, shares.within200ms)] {
            let forward = Self.matched(b, in: a, tolerance: tolerance)
            let backward = Self.matched(a, in: b, tolerance: tolerance)
            #expect(
                forward >= share && backward >= share, "\(comment): within \(tolerance) s \(forward), \(backward)",
                sourceLocation: sourceLocation)
        }
        let difference = abs(Double(b.count - a.count)) / Double(max(1, a.count))
        #expect(
            difference <= 0.01, "\(comment): \(b.count) cycles, \(a.count) at 100 Hz", sourceLocation: sourceLocation)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var sport: Sport
        var strokeRate: Double
        var seed: UInt64
        var harmonic = 0.35
        var noisy = false
        var testDescription: String { "\(sport.rawValue) \(Int(strokeRate)) spm seed \(seed)\(noisy ? " noisy" : "")" }

        var simulator: PaddleMotionSimulator {
            var simulator = PaddleMotionSimulator(
                sport: sport, segments: [.init(duration: 300, strokeRate: strokeRate)])
            simulator.seed = seed
            simulator.harmonic = harmonic
            if noisy {
                simulator.rotationNoise = 0.3
                simulator.accelerationNoise = 1.0
                simulator.amplitudeJitter = 0.3
            }
            return simulator
        }
    }

    static let cases: [Case] = [
        Case(sport: .kayak, strokeRate: 50, seed: 50), Case(sport: .kayak, strokeRate: 70, seed: 70),
        Case(sport: .kayak, strokeRate: 90, seed: 90), Case(sport: .canoe, strokeRate: 30, seed: 130),
        Case(sport: .canoe, strokeRate: 50, seed: 150), Case(sport: .sup, strokeRate: 60, seed: 160),
        Case(sport: .kayak, strokeRate: 64, seed: 21, harmonic: 0.5, noisy: true),
        Case(sport: .kayak, strokeRate: 60, seed: 4, harmonic: 0.1),
    ]

    @Test(arguments: cases)
    func decimatingTo50HzKeepsTheCycles(_ test: Case) {
        let motion = test.simulator.generate().samples
        let reference = Self.cycles(motion, sport: test.sport)
        expectSameCycles(Self.cycles(Self.decimated(motion, phase: 0), sport: test.sport), reference, "even samples")
        expectSameCycles(Self.cycles(Self.decimated(motion, phase: 1), sport: test.sport), reference, "odd samples")
        expectSameCycles(Self.cycles(Self.pairAveraged(motion), sport: test.sport), reference, "pairs averaged")
    }

    @Test(arguments: cases)
    func shiftingTheBinsKeepsTheCycles(_ test: Case) {
        // The same motion 5 ms and 20 ms later falls into differently phased 40 ms bins.
        let motion = test.simulator.generate().samples
        let reference = Self.cycles(motion, sport: test.sport)
        for shift in [0.005, 0.02] {
            let moved = motion.map { sample in
                var sample = sample
                sample.t += shift
                return sample
            }
            let cycles = Self.cycles(moved, sport: test.sport).map { cycle in
                var cycle = cycle
                cycle.t -= shift
                return cycle
            }
            expectSameCycles(cycles, reference, "shifted \(shift) s")
        }
    }

    /// Bouts of paddling with rests between them, switching sides (canoe, SUP) after each
    /// rest: the case that broke on the real recording. At rest the main axis follows noise,
    /// so a sign carried through the rest came out either way, and 100 and 50 Hz agreed on
    /// only 17–98 % of the cycles. A few cycles where a bout starts or stops may differ.
    @Test(arguments: [(Sport.kayak, UInt64(1)), (.kayak, 3), (.kayak, 5), (.canoe, 1), (.canoe, 3), (.sup, 2)])
    func restsBetweenBoutsKeepTheCyclesAt50Hz(sport: Sport, seed: UInt64) {
        var segments: [PaddleMotionSimulator.Segment] = []
        for bout in 0..<6 {
            segments.append(.init(duration: 60, strokeRate: sport == .kayak ? 60 : 45, side: bout % 2))
            segments.append(.init(duration: 20, strokeRate: 0, side: bout % 2))
        }
        var simulator = PaddleMotionSimulator(sport: sport, segments: segments)
        simulator.seed = seed
        let motion = simulator.generate().samples
        let reference = Self.cycles(motion, sport: sport)
        let shares = (within40ms: 0.95, within200ms: 0.98)
        // What the user sees: the count within 2 strokes or 1 %, the average rate within
        // 1 spm. (They are equal here; before #178 they differed by up to 4 kayak strokes.)
        let whole = Self.strokes(motion, sport: sport)
        for phase in [0, 1] {
            let other = Self.strokes(Self.decimated(motion, phase: phase), sport: sport)
            let bound = max(2, Int((0.01 * Double(whole.count)).rounded(.up)))
            #expect(abs(other.count - whole.count) <= bound, "phase \(phase): \(other.count) strokes, \(whole.count)")
            if let a = other.rate, let b = whole.rate {
                #expect(abs(a - b) <= 1, "phase \(phase): \(a) spm, \(b)")
            } else {
                Issue.record("phase \(phase): no average rate")
            }
        }
        expectSameCycles(Self.cycles(Self.decimated(motion, phase: 0), sport: sport), reference, "even", shares: shares)
        expectSameCycles(Self.cycles(Self.decimated(motion, phase: 1), sport: sport), reference, "odd", shares: shares)
        let shifted = motion.map { sample in
            var sample = sample
            sample.t += 0.005
            return sample
        }
        let cycles = Self.cycles(shifted, sport: sport).map { cycle in
            var cycle = cycle
            cycle.t -= 0.005
            return cycle
        }
        expectSameCycles(cycles, reference, "shifted 5 ms", shares: shares)
        if sport != .kayak {
            // The same cycles keep the same sides.
            let decimated = Self.cycles(Self.decimated(motion, phase: 1), sport: sport)
            var agree = 0
            var compared = 0
            for cycle in decimated {
                guard let match = reference.first(where: { abs($0.t - cycle.t) <= 0.04 }) else { continue }
                compared += 1
                if match.side == cycle.side { agree += 1 }
            }
            #expect(Double(agree) >= 0.98 * Double(compared), "sides agree on \(agree) of \(compared)")
        }
    }

    /// Paddling simulated at 50 and at 100 Hz (different noise) puts each cycle's peak on
    /// the same lobe of the true cycle: within 0.1 of a period (the other lobe is about 0.2
    /// away), with the same typical offset within 40 ms.
    @Test(arguments: cases)
    func simulatedAt50And100HzPeaksOnTheSameLobe(_ test: Case) {
        var offsets: [[Int: Double]] = []
        for rate in [100.0, 50.0] {
            var simulator = test.simulator
            simulator.sampleRate = rate
            let output = simulator.generate()
            let truth = output.cycleTimes
            var byCycle: [Int: Double] = [:]
            for cycle in Self.cycles(output.samples, sport: test.sport) {
                guard let nearest = truth.indices.min(by: { abs(truth[$0] - cycle.t) < abs(truth[$1] - cycle.t) })
                else { continue }
                byCycle[nearest] = cycle.t - truth[nearest]
            }
            #expect(
                abs(byCycle.count - truth.count) <= max(2, truth.count / 50),
                "\(rate) Hz: \(byCycle.count) of \(truth.count)")
            offsets.append(byCycle)
        }
        let period = 60 * Double(test.sport == .kayak ? 2 : 1) / test.strokeRate
        let common = offsets[0].keys.filter { offsets[1][$0] != nil }
        let same = common.filter { abs(offsets[0][$0]! - offsets[1][$0]!) <= 0.1 * period }
        #expect(Double(same.count) >= 0.99 * Double(common.count), "same lobe in \(same.count) of \(common.count)")
        let typical = offsets.map { StrokeDetector.median(Array($0.values)) }
        #expect(abs(typical[0] - typical[1]) <= 0.04, "typical offsets \(typical)")
    }

    /// The root cause: negating the motion leaves the principal axis as it was (the
    /// covariance is the same), so with the sign carried from the first axis the projection
    /// came out negated and the other lobe became the peak. The sign now follows the
    /// signal's skewness, so the projection and the cycles are the same.
    @Test(arguments: [Sport.kayak, .canoe, .sup])
    func negatedMotionFindsTheSameCycles(sport: Sport) {
        var simulator = PaddleMotionSimulator(sport: sport, segments: [.init(duration: 200, strokeRate: 56)])
        simulator.seed = 31
        let motion = simulator.generate().samples
        let negated = motion.map { sample in
            var sample = sample
            sample.rotationRate = Vector3(
                x: -sample.rotationRate.x, y: -sample.rotationRate.y, z: -sample.rotationRate.z)
            sample.userAcceleration = Vector3(
                x: -sample.userAcceleration.x, y: -sample.userAcceleration.y, z: -sample.userAcceleration.z)
            return sample
        }
        let a = Self.cycles(motion, sport: sport).map(\.t)
        let b = Self.cycles(negated, sport: sport).map(\.t)
        #expect(a.count == b.count)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    /// After a sensor gap the axis is found afresh, and its sign with it: the cycles after
    /// the gap must not depend on the sign before it.
    @Test func cyclesAfterASensorGapDoNotDependOnTheSignBeforeIt() {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 240, strokeRate: 60)])
        simulator.seed = 37
        let motion = simulator.generate().samples
        let gap = 100.0...101.0
        let withGap = motion.filter { !gap.contains($0.t) }
        // Only the part after the gap, from scratch, against the whole recording.
        let after = withGap.filter { $0.t > gap.upperBound }
        let whole = Self.cycles(withGap, sport: .kayak).filter { $0.t > gap.upperBound + 20 }
        let fresh = Self.cycles(after, sport: .kayak).filter { $0.t > gap.upperBound + 20 }
        expectSameCycles(fresh, whole, "after the gap")
    }

    /// A polarity flip moves the peak to the other lobe; the interval across it is not a
    /// period, so the rate does not jump. The second harmonic changes sign over 30 cycles
    /// from 120 s: the axis stays, but the projection's skewness turns negative, so the
    /// running skewness flips the sign a while later. (The review of #178 found that the
    /// earlier version of this test never flipped.) Canoe, one lobe per stroke: on the
    /// wrong sign the broad lobe of a slower kayak cycle has no clear peak.
    @Test(arguments: [50.0, 40.0])
    func noPeriodSpansAPolarityFlip(rate: Double) {
        let sport = Sport.canoe
        var simulator = PaddleMotionSimulator(sport: sport, segments: [.init(duration: 120, strokeRate: rate)])
        simulator.seed = 50
        simulator.harmonic = 0.5
        var motion = simulator.generate().samples
        let cycle = 60.0 * (sport == .kayak ? 2 : 1) / rate
        for step in 1...90 {
            simulator.seed = 50 + UInt64(step)
            simulator.harmonic = 0.5 - min(1, Double(step) / 30)
            simulator.segments = [.init(duration: cycle, strokeRate: rate)]
            // Each part ends on a whole cycle, so the cadence carries on.
            simulator.startTime = (motion.last?.t ?? 0) + 1 / simulator.sampleRate
            motion += simulator.generate().samples
        }
        var detector = StrokeDetector(sport: sport, recordsCycles: true)
        for sample in motion { detector.ingest(sample) }
        detector.finish()
        #expect(detector.polarityFlips >= 1, "no flip")
        let basePeriod = 60.0 * Double(detector.strokesPerCycle) / rate
        let cycles = detector.cycles
        // The flip did move the peak: an interval across it is far from the cadence...
        let jumps = zip(cycles, cycles.dropFirst()).filter { abs($1.t - $0.t - basePeriod) > 0.15 * basePeriod }
        #expect(!jumps.isEmpty, "no peak moved to the other lobe")
        // ...and it is not a period.
        for cycle in cycles {
            if let period = cycle.period {
                #expect(abs(period - basePeriod) <= 0.15 * basePeriod, "period \(period) at \(cycle.t)")
            }
        }
    }

    /// The device frame turned by `angle` (radians) about the paddle frame's third axis,
    /// which turns the main axis of motion by the same angle: at once at `from`, or evenly
    /// over `over` seconds from it.
    static func turned(_ motion: [MotionSample], from: Double, over: Double = 0, by angle: Double) -> [MotionSample] {
        let pose = PaddleMotionSimulator.pose(side: 0)
        let inverse = (0..<3).map { i in (0..<3).map { j in pose[j][i] } }
        return motion.map { sample in
            guard sample.t >= from else { return sample }
            let share = over > 0 ? min(1, (sample.t - from) / over) : 1
            let rotation = PaddleMotionSimulator.multiply(
                pose, PaddleMotionSimulator.multiply(PaddleMotionSimulator.rotationZ(share * angle), inverse))
            func rotate(_ v: Vector3) -> Vector3 {
                let r = PaddleMotionSimulator.apply(rotation, [v.x, v.y, v.z])
                return Vector3(x: r[0], y: r[1], z: r[2])
            }
            var sample = sample
            sample.rotationRate = rotate(sample.rotationRate)
            sample.userAcceleration = rotate(sample.userAcceleration)
            sample.gravity = rotate(sample.gravity)
            return sample
        }
    }

    struct TurnCase: Sendable, CustomTestStringConvertible {
        var sport: Sport
        var harmonic: Double
        var testDescription: String { "\(sport.rawValue) harmonic \(harmonic)" }
    }

    static let turnCases: [TurnCase] = [Sport.canoe, .sup, .kayak].flatMap { sport in
        [0.03, 0.15, 0.35].map { TurnCase(sport: sport, harmonic: $0) }
    }

    /// The watch turns on the wrist by 30–180° 20 s into the session, at once or over 2, 6 or
    /// 12 s (each angle with a different duration for each seed, so five seeds cover them
    /// all), at both 50 Hz sample phases. Canoe and SUP paddle 2 minutes at 30 spm, kayak 4
    /// minutes at 60 spm (a missed or extra kayak cycle is 2 strokes, which needs the longer
    /// session to stay within the rate bound). The two rates may settle on different lobes of
    /// a nearly symmetric stroke (harmonic 0.03), but what the user sees agrees:
    ///
    /// - the stroke count within 3 cycles or 1 %, whichever is larger. A sign decision that
    ///   moves the peak to the other lobe adds or drops a cycle, depending on where in the
    ///   cycle it falls, so the rates can differ by a cycle per decision: at most 2 cycles
    ///   over the full grid of every angle with every duration (1.6 % of runs);
    /// - the average rate within 1 spm;
    /// - canoe and SUP: the side of at least 98 % of the strokes from 8 s after the turn
    ///   (all of them on the full grid), each matched to the nearest 100 Hz stroke.
    ///
    /// This replaces a test that required the same stroke times through a 96–114° turn.
    @Test(arguments: turnCases)
    func turnsKeepTheCountRateAndSideAt50Hz(_ test: TurnCase) {
        let sport = test.sport
        let strokesPerCycle = sport == .kayak ? 2 : 1
        let period = 2.0
        let durations = [0.0, 2, 6, 12]
        var issues: [String] = []
        let length = sport == .kayak ? 240.0 : 120
        for seed in 1...5 {
            var simulator = PaddleMotionSimulator(
                sport: sport, segments: [.init(duration: length, strokeRate: 60 * Double(strokesPerCycle) / period)])
            simulator.seed = UInt64(seed)
            simulator.harmonic = test.harmonic
            let samples = simulator.generate().samples
            for (index, degrees) in stride(from: 30.0, through: 180, by: 30).enumerated() {
                let over = durations[(index + seed) % durations.count]
                let motion = Self.turned(samples, from: 20, over: over, by: degrees * .pi / 180)
                let reference = Self.strokes(motion, sport: sport)
                let bound = max(3 * strokesPerCycle, Int((0.01 * Double(reference.count)).rounded(.up)))
                for phase in [0, 1] {
                    let name = "seed \(seed), \(Int(degrees))° over \(over) s, phase \(phase)"
                    let other = Self.strokes(Self.decimated(motion, phase: phase), sport: sport)
                    if abs(other.count - reference.count) > bound {
                        issues.append("\(name): \(other.count) strokes, \(reference.count) at 100 Hz")
                    }
                    if let a = other.rate, let b = reference.rate {
                        if abs(a - b) > 1 { issues.append("\(name): \(a) spm, \(b) at 100 Hz") }
                    } else {
                        issues.append("\(name): no average rate")
                    }
                    guard sport != .kayak else { continue }
                    let sides = Self.sideAgreement(
                        other.cycles, reference.cycles, after: 20 + over + 8, tolerance: 0.6 * period)
                    if sides.compared < 30 || Double(sides.agree) < 0.98 * Double(sides.compared) {
                        issues.append("\(name): sides agree on \(sides.agree) of \(sides.compared)")
                    }
                }
            }
        }
        #expect(issues.isEmpty, "\(issues.count) runs: \(issues.prefix(10))")
    }

    /// Review of #178: a turned axis that took its own sign could move the peak to the other
    /// lobe, but only a flip kept the interval across it out of the rate (2.3 s at a steady
    /// 2.0 s cadence). The watch turns slowly here, so the motion itself has no step.
    @Test(arguments: [72.0, 105.0, 150.0])
    func noPeriodSpansATurnedAxis(degrees: Double) {
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 60, strokeRate: 30)])
        simulator.seed = 3
        simulator.periodJitter = 0.02
        let motion = Self.turned(simulator.generate().samples, from: 20, over: 6, by: degrees * .pi / 180)
        let streams = [
            ("100 Hz", motion), ("even", Self.decimated(motion)), ("odd", Self.decimated(motion, phase: 1)),
        ]
        for (name, stream) in streams {
            var detector = StrokeDetector(sport: .canoe, recordsCycles: true)
            for sample in stream { detector.ingest(sample) }
            detector.finish()
            #expect(detector.axisTurns + detector.polarityFlips >= 1, "\(name): the sign was never decided again")
            for cycle in detector.cycles {
                guard let period = cycle.period else { continue }
                #expect(abs(period - 2) <= 0.15, "\(name): period \(period) at \(cycle.t)")
            }
        }
    }

    /// Review of #178: the first axis waited for a full 3 s window, and a sensor gap
    /// restarted before it, so paddling in stretches shorter than that counted nothing.
    @Test(arguments: [100.0, 50.0])
    func strokesBetweenShortSensorGapsCount(rate: Double) {
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 30, strokeRate: 30)])
        simulator.seed = 7
        simulator.sampleRate = rate
        let output = simulator.generate()
        // Ten 2.5 s stretches with 0.5 s gaps between them.
        let stretches = output.samples.filter { $0.t.truncatingRemainder(dividingBy: 3) < 2.5 }
        let truth = output.cycleTimes.filter { $0.truncatingRemainder(dividingBy: 3) < 2.5 }
        let cycles = Self.cycles(stretches, sport: .canoe)
        #expect(cycles.count >= truth.count - 4, "\(cycles.count) cycles of \(truth.count)")
    }

    /// Review of #178: a recording shorter than the 3 s window found no axis, so its strokes
    /// were lost. The end decides the axis from what there is, on session detail's path and
    /// on the live one (`finish()`).
    @Test(arguments: [100.0, 50.0])
    func aRecordingShorterThanTheWindowCountsItsStrokes(rate: Double) {
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 2.4, strokeRate: 50)])
        simulator.seed = 9
        simulator.sampleRate = rate
        let output = simulator.generate()
        #expect((output.samples.last?.t ?? 0) < 3)
        let detection = StrokeAnalysis.detect(motion: output.samples, sport: .canoe)
        #expect(
            detection.cycles.count >= output.cycleTimes.count - 1,
            "\(detection.cycles.count) of \(output.cycleTimes.count)")
        #expect(!detection.cycles.isEmpty)
    }

    /// Re-check of #178 (blocking): the axis took 0.15 × the last minute's moments, so it kept
    /// the old axis for about 40 s after a grip change and missed half the strokes (29 of
    /// 61; main found them). Canoe at 60 spm; at 120 s the watch turns 90° and the peak
    /// rotation drops from 3 to 0.8 rad/s. Simulated natively at 100 and 50 Hz.
    @Test(arguments: [100.0, 50.0])
    func aGripChangeIsFollowedWithinAFewStrokes(rate: Double) {
        var before = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 120, strokeRate: 60)])
        before.seed = 1
        before.sampleRate = rate
        before.rotationAmplitude = 3
        before.accelerationAmplitude = 7.5
        let first = before.generate()
        var after = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 60, strokeRate: 60)])
        after.seed = 101
        after.sampleRate = rate
        after.rotationAmplitude = 0.8
        after.accelerationAmplitude = 2
        after.startTime = (first.samples.last?.t ?? 0) + 1 / rate
        let second = after.generate()
        let motion = first.samples + Self.turned(second.samples, from: 0, by: .pi / 2)
        let cycles = Self.cycles(motion, sport: .canoe).map(\.t)
        let truth = second.cycleTimes
        let found = cycles.filter { $0 > 120 }
        #expect(found.count >= truth.count - 3, "\(found.count) of \(truth.count) strokes after the change")
        // Within a few strokes of the change, and every 10 s after it.
        for start in stride(from: 124.0, to: 180, by: 10) {
            let block = start..<(start + 10)
            let expected = truth.filter { block.contains($0) }.count
            let counted = cycles.filter { block.contains($0) }.count
            #expect(counted >= expected - 1, "\(counted) of \(expected) strokes in \(block)")
        }
    }

    /// Re-check of #178: the minimum stretch for an axis was a count of bins (25), so one
    /// 0.96 s canoe stroke spanned 24 or 25 bins depending on where the 40 ms bins fell, and
    /// counted 0 or 1 stroke with a 10 ms shift. The minimum is now the time from the first to
    /// the last sample (1 s), whatever the bins' alignment, so every shift counts the same.
    @Test(arguments: [100.0, 50.0])
    func aShortTraceCountsTheSameWhateverItsBinPhase(rate: Double) {
        var counts: [Int] = []
        for shift in stride(from: 0.0, to: 0.04, by: 0.005) {
            var simulator = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 0.96, strokeRate: 64)])
            simulator.seed = 9
            simulator.sampleRate = rate
            simulator.startTime = shift
            let samples = simulator.generate().samples.filter { $0.t < shift + 0.96 }
            counts.append(Self.cycles(samples, sport: .canoe).count)
        }
        #expect(Set(counts).count == 1, "counts by shift: \(counts)")
    }

    /// Re-check of #178: only the latest sign decision was kept. A turn and then a flip, or
    /// a decision after a peak but before its cycle ended, left an interval across the earlier
    /// decision counted as a period, though the peak may have moved to the other lobe there.
    /// Every decision since the last peak now counts. A canoe at 30 spm turns 120–180°.
    @Test func noPeriodSpansAnyOfSeveralSignDecisions() {
        var close = 0
        for seed in UInt64(1)...5 {
            var simulator = PaddleMotionSimulator(sport: .canoe, segments: [.init(duration: 60, strokeRate: 30)])
            simulator.seed = seed
            let samples = simulator.generate().samples
            for (degrees, over) in [(120.0, 0.0), (150, 4), (180, 6)] {
                let motion = Self.turned(samples, from: 20, over: over, by: degrees * .pi / 180)
                for (name, stream) in [("100 Hz", motion), ("even", Self.decimated(motion))] {
                    var detector = StrokeDetector(sport: .canoe, recordsCycles: true)
                    for sample in stream { detector.ingest(sample) }
                    detector.finish()
                    let decisions = detector.signDecisionLog
                    close += zip(decisions, decisions.dropFirst()).filter { $1 - $0 < 2 }.count
                    for cycle in detector.cycles {
                        guard let period = cycle.period else { continue }
                        let spanned = decisions.filter { cycle.t - period < $0 && $0 <= cycle.t }
                        #expect(
                            spanned.isEmpty,
                            "seed \(seed) \(Int(degrees))° \(name): period \(period) at \(cycle.t) spans \(spanned)")
                    }
                }
            }
        }
        // The case this is about: sign decisions less than a cycle apart.
        #expect(close > 0)
    }
}
