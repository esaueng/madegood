import Foundation
import Testing

@testable import WaterKit

/// The detector must find the same wrist cycles at 50 Hz as at 100 Hz (docs/metrics.md
/// "Strokes"). A real 100 Hz kayak recording decimated to 50 Hz kept its stroke count, but
/// most cycles moved by about ±450 ms: the principal axis's sign is arbitrary, it decides
/// which lobe of the wrist cycle is the peak, and the first sign was carried through the
/// session. Any small change (sample rate, bin phase, start time) could pick the other one.
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
    /// period, so the rate does not jump.
    @Test func noPeriodSpansAPolarityFlip() {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 300, strokeRate: 50)])
        simulator.seed = 50
        let output = simulator.generate()
        var detector = StrokeDetector(sport: .kayak, recordsCycles: true)
        for sample in output.samples { detector.ingest(sample) }
        let basePeriod = 60.0 * 2 / 50
        for cycle in detector.cycles {
            if let period = cycle.period {
                #expect(abs(period - basePeriod) <= 0.15 * basePeriod, "period \(period) at \(cycle.t)")
            }
        }
    }
}
