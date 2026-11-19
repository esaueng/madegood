import Foundation
import Testing

@testable import WaterKit

// No labeled paddling recordings exist yet (fixtures/ holds one sailing fixture), so the
// PLAN §5 accuracy targets (count within ±3 %, rate within ±2 SPM) are checked against
// synthetic wrist motion with known strokes: noise, jitter, pauses, rate changes, side
// switches, sensor gaps and different sample rates.
@Suite struct StrokeDetectorTests {
    typealias Segment = PaddleMotionSimulator.Segment

    struct Run {
        var output: PaddleMotionSimulator.Output
        var metrics: StrokeDetector.Metrics
        /// Live snapshots once per second.
        var rates: [(t: Double, rate: Double?, lastStroke: Double?)]

        /// The true rate over the (up to) six cycles before the true cycle nearest `peak`, SPM: the
        /// paddler's actual recent rate, which wanders around the segment's nominal rate.
        func trueRate(endingAt peak: Double, strokesPerCycle: Int) -> Double? {
            let times = output.cycleTimes
            guard let end = times.indices.min(by: { abs(times[$0] - peak) < abs(times[$1] - peak) }),
                end >= 2
            else { return nil }
            let cycles = min(6, end)
            return 60 * Double(cycles * strokesPerCycle) / (times[end] - times[end - cycles])
        }
    }

    func run(_ simulator: PaddleMotionSimulator, config: StrokeDetector.Config = StrokeDetector.Config()) -> Run {
        let output = simulator.generate()
        var detector = StrokeDetector(sport: simulator.sport, config: config)
        var rates: [(Double, Double?, Double?)] = []
        var nextSecond = simulator.startTime + 1
        for sample in output.samples {
            detector.ingest(.motion(sample))
            if sample.t >= nextSecond {
                rates.append((sample.t, detector.snapshot.strokeRate, detector.snapshot.lastStrokeAt))
                nextSecond += 1
            }
        }
        return Run(output: output, metrics: detector.snapshot, rates: rates)
    }

    func expectCount(_ run: Run, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let truth = Double(run.output.strokeCount)
        let error = abs(Double(run.metrics.strokeCount) - truth) / truth
        #expect(
            error <= 0.03, "\(comment?.rawValue ?? "") counted \(run.metrics.strokeCount) of \(run.output.strokeCount)",
            sourceLocation: sourceLocation)
    }

    /// Live rates during steady paddling (after `settle` s into each segment) are within
    /// ±2 SPM of the true recent rate, and within ±4 SPM of the segment's nominal rate.
    func expectRates(
        _ run: Run, segments: [Segment], start: Double = 0, settle: Double = 15,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let strokesPerCycle = run.output.strokeCount / max(1, run.output.cycleTimes.count)
        var segmentStart = start
        var checked = 0
        for segment in segments {
            defer { segmentStart += segment.duration }
            guard segment.strokeRate > 0 else { continue }
            let window = (segmentStart + settle)...(segmentStart + segment.duration - 3)
            for (t, rate, lastStroke) in run.rates where window.contains(t) {
                checked += 1
                guard let rate, let lastStroke,
                    let truth = run.trueRate(endingAt: lastStroke, strokesPerCycle: strokesPerCycle)
                else {
                    Issue.record("no rate at \(t) s", sourceLocation: sourceLocation)
                    continue
                }
                #expect(
                    abs(rate - truth) <= 2, "rate \(rate) at \(t) s, true \(truth)", sourceLocation: sourceLocation)
                #expect(
                    abs(rate - segment.strokeRate) <= 4, "rate \(rate) at \(t) s, nominal \(segment.strokeRate)",
                    sourceLocation: sourceLocation)
            }
        }
        #expect(checked > 0, sourceLocation: sourceLocation)
    }

    @Test(arguments: [50.0, 70.0, 90.0])
    func kayakSteadyRateCountsTwoStrokesPerCycle(strokeRate: Double) {
        let segments = [Segment(duration: 300, strokeRate: strokeRate)]
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: segments)
        simulator.seed = UInt64(strokeRate)
        let result = run(simulator)
        expectCount(result)
        #expect(result.metrics.strokeCount.isMultiple(of: 2))
        expectRates(result, segments: segments)
    }

    @Test(arguments: [30.0, 50.0, 70.0])
    func canoeSteadyRate(strokeRate: Double) {
        let segments = [Segment(duration: 300, strokeRate: strokeRate)]
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: segments)
        simulator.seed = UInt64(strokeRate) + 100
        let result = run(simulator)
        expectCount(result)
        expectRates(result, segments: segments)
        #expect(result.metrics.sideSwitches == 0)
    }

    @Test func supWithPausesAndRateChanges() {
        let segments = [
            Segment(duration: 120, strokeRate: 45), Segment(duration: 30, strokeRate: 0),
            Segment(duration: 120, strokeRate: 60), Segment(duration: 20, strokeRate: 0),
            Segment(duration: 120, strokeRate: 52),
        ]
        var simulator = PaddleMotionSimulator(sport: .sup, segments: segments)
        simulator.seed = 7
        let result = run(simulator)
        expectCount(result)
        expectRates(result, segments: segments)
        // The rate blanks during a pause once the last cycle is stale.
        let pauses = [(120.0 + 10)...(150.0 - 1), (270.0 + 10)...(290.0 - 1)]
        for (t, rate, _) in result.rates where pauses.contains(where: { $0.contains(t) }) {
            #expect(rate == nil, "rate \(rate ?? 0) during a pause at \(t) s")
        }
    }

    @Test func canoeSideSwitchesAreDetected() {
        var segments: [Segment] = []
        for index in 0..<8 { segments.append(Segment(duration: 40, strokeRate: 50, side: index % 2)) }
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: segments)
        simulator.seed = 11
        let result = run(simulator)
        expectCount(result)
        #expect(result.metrics.sideSwitches == result.output.sideSwitches)
        expectRates(result, segments: segments, settle: 20)
    }

    @Test func noisyHarmonicHeavySignalStillCountsCycles() {
        let segments = [Segment(duration: 240, strokeRate: 64)]
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: segments)
        simulator.harmonic = 0.5
        simulator.rotationNoise = 0.3
        simulator.accelerationNoise = 1.0
        simulator.amplitudeJitter = 0.3
        simulator.seed = 21
        let result = run(simulator)
        expectCount(result)
        expectRates(result, segments: segments)
    }

    @Test func lowerSampleRateAndLaterStartGiveTheSameResult() {
        let segments = [Segment(duration: 180, strokeRate: 56, side: 0), Segment(duration: 180, strokeRate: 56, side: 1)]
        var simulator = PaddleMotionSimulator(sport: .sup, segments: segments)
        simulator.sampleRate = 50
        simulator.startTime = -12.37
        simulator.seed = 5
        let result = run(simulator)
        expectCount(result)
        expectRates(result, segments: segments, start: -12.37, settle: 20)
        #expect(result.metrics.sideSwitches == 1)
    }

    @Test func restingWristCountsNothing() {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [Segment(duration: 300, strokeRate: 0)])
        simulator.seed = 3
        let result = run(simulator)
        #expect(result.metrics.strokeCount == 0)
        #expect(result.rates.allSatisfy { $0.rate == nil })
    }

    @Test func restingRepositoryFixtureCountsNothing() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = repository.appendingPathComponent("fixtures/sailing/synthetic-straight-line")
        let recording = try RawSessionReader.read(folder: folder)
        #expect(recording.motion.count > 1000)
        let analysis = StrokeAnalysis(motion: recording.motion, sport: .kayak, distance: 332)
        #expect(analysis.strokeCount == 0)
        #expect(analysis.averageStrokeRate == nil)
        #expect(analysis.distancePerStroke == nil)
    }

    @Test func sensorGapRestartsWithoutPhantomStrokes() {
        let segments = [Segment(duration: 200, strokeRate: 60, side: 0)]
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: segments)
        simulator.seed = 9
        let output = simulator.generate()
        // Drop 3 s of samples in the middle.
        let gap = 100.0...103.0
        let samples = output.samples.filter { !gap.contains($0.t) }
        var detector = StrokeDetector(sport: .canoe)
        for sample in samples { detector.ingest(sample) }
        let lost = output.cycleTimes.filter { gap.contains($0) }.count
        let truth = Double(output.strokeCount - lost)
        // The filters restart after the gap and need a few cycles to settle.
        #expect(abs(Double(detector.snapshot.strokeCount) - truth) <= max(3, truth * 0.03))
        #expect(detector.snapshot.strokeRate.map { abs($0 - 60) <= 2 } == true)
    }

    @Test func ignoresNonFiniteAndOutOfOrderSamples() {
        let segments = [Segment(duration: 120, strokeRate: 60)]
        var simulator = PaddleMotionSimulator(sport: .sup, segments: segments)
        simulator.seed = 13
        let output = simulator.generate()
        var clean = StrokeDetector(sport: .sup)
        var noisy = StrokeDetector(sport: .sup)
        for (index, sample) in output.samples.enumerated() {
            clean.ingest(sample)
            noisy.ingest(sample)
            if index.isMultiple(of: 97) {
                var bad = sample
                bad.rotationRate.x = .nan
                noisy.ingest(bad)
                var late = sample
                late.t -= 1
                noisy.ingest(late)
                var infinite = sample
                infinite.t = .infinity
                noisy.ingest(infinite)
            }
        }
        #expect(noisy.snapshot.strokeCount == clean.snapshot.strokeCount)
        #expect(clean.snapshot.strokeCount > 100)
    }

    @Test func rateBlanksWhenTheClockAdvancesWithoutSamples() throws {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [Segment(duration: 60, strokeRate: 70)])
        simulator.seed = 17
        let output = simulator.generate()
        var detector = StrokeDetector(sport: .kayak)
        for sample in output.samples { detector.ingest(sample) }
        #expect(detector.snapshot.strokeRate != nil)
        let last = try #require(output.samples.last?.t)
        detector.advance(to: last + 10)
        #expect(detector.snapshot.strokeRate == nil)
        #expect(detector.snapshot.strokeCount > 0)
    }

    // MARK: - Post-session analysis

    @Test func postAnalysisReportsStrokesRateAndDistancePerStroke() throws {
        let segments = [
            Segment(duration: 120, strokeRate: 72), Segment(duration: 30, strokeRate: 0),
            Segment(duration: 120, strokeRate: 80),
        ]
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: segments)
        simulator.seed = 23
        let output = simulator.generate()
        let analysis = StrokeAnalysis(motion: output.samples, sport: .kayak, distance: 1000)
        let truth = Double(output.strokeCount)
        #expect(abs(Double(analysis.strokeCount) - truth) / truth <= 0.03)
        let average = try #require(analysis.averageStrokeRate)
        #expect(abs(average - output.averageStrokeRate) <= 2)
        #expect(analysis.distancePerStroke.map { abs($0 - 1000 / Double(analysis.strokeCount)) < 1e-9 } == true)
        #expect(analysis.sideBalance == nil)
        #expect(analysis.strokes.allSatisfy { $0.side == nil })
        // Strokes are in time order, and kayak strokes alternate between cycle peaks.
        #expect(zip(analysis.strokes, analysis.strokes.dropFirst()).allSatisfy { $0.t < $1.t })
        // The rate series follows the change from 72 to 80 SPM and has no point in the pause.
        let early = analysis.rateSeries.filter { (20...110).contains($0.t) }
        let late = analysis.rateSeries.filter { (175...265).contains($0.t) }
        // Points cover four cycles, so they wander with the paddler's ±4 % period jitter;
        // their mean matches the nominal rate.
        for (points, nominal) in [(early, 72.0), (late, 80.0)] {
            #expect(points.count > 20)
            #expect(points.allSatisfy { abs($0.strokeRate - nominal) <= 4 })
            #expect(abs(points.reduce(0) { $0 + $1.strokeRate } / Double(points.count) - nominal) <= 1)
        }
        #expect(analysis.rateSeries.allSatisfy { !(125...148).contains($0.t) })
    }

    @Test func postAnalysisReportsSideBalance() throws {
        let segments = [
            Segment(duration: 90, strokeRate: 50, side: 0), Segment(duration: 30, strokeRate: 50, side: 1),
        ]
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: segments)
        simulator.seed = 29
        let output = simulator.generate()
        let analysis = StrokeAnalysis(motion: output.samples, sport: .canoe, distance: nil)
        #expect(analysis.sideSwitches == 1)
        #expect(analysis.distancePerStroke == nil)
        let balance = try #require(analysis.sideBalance)
        #expect(abs(balance - 0.75) <= 0.05)
    }

    @Test func selectionKeepsOnlyRetainedStrokesOnTheReplayClock() throws {
        let segments = [Segment(duration: 200, strokeRate: 60)]
        var simulator = PaddleMotionSimulator(sport: .sup, segments: segments)
        simulator.seed = 31
        let output = simulator.generate()
        let full = StrokeAnalysis(motion: output.samples, sport: .sup, distance: 500)
        let retained = [10.0...60.0, 100.0...150.0]
        let trimmed = StrokeAnalysis(
            motion: output.samples, sport: .sup, distance: 250, retained: retained, clock: { $0 - 10 })
        let expected = full.strokes.filter { stroke in retained.contains { $0.contains(stroke.t) } }
        #expect(trimmed.strokes.map(\.t) == expected.map { $0.t - 10 })
        #expect(trimmed.strokeCount > 90 && trimmed.strokeCount < 110)
        // No rate point spans the removed interval.
        #expect(trimmed.rateSeries.allSatisfy { !(50...90).contains($0.t) || $0.t <= 50 })
        #expect(abs((trimmed.averageStrokeRate ?? 0) - 60) <= 2)
    }

    @Test func selectionOfARawSessionUsesItsDistanceAndClock() throws {
        let segments = [Segment(duration: 120, strokeRate: 60)]
        var simulator = PaddleMotionSimulator(sport: .sup, segments: segments)
        simulator.seed = 37
        let output = simulator.generate()
        let fixes = (0...120).map { second in
            GPSFix(
                t: Double(second), latitude: 10, longitude: -30 + Double(second) * 2 / 109_600,
                horizontalAccuracy: 5, speed: 2, course: 90)
        }
        let startUnix = 946_684_800.0
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .sup, startedAt: startUnix, endedAt: startUnix + 121,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"),
            requestedRates: [:])
        let session = RawSession(meta: meta, gps: fixes, motion: output.samples)
        let selection = try SessionSelection(session: session)
        let analysis = StrokeAnalysis(session: session, selection: selection)
        #expect(abs(Double(analysis.strokeCount) - Double(output.strokeCount)) <= 3)
        let distance = selection.replay.metrics.distance
        #expect(distance > 200)
        #expect(analysis.distancePerStroke.map { abs($0 - distance / Double(analysis.strokeCount)) < 1e-9 } == true)
    }

    @Test func replayStatsReportStrokesForPaddlingRecordingsOnly() throws {
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: [Segment(duration: 60, strokeRate: 50)])
        simulator.seed = 43
        let output = simulator.generate()
        let startUnix = 946_684_800.0
        func session(_ sport: Sport) -> RawSession {
            let meta = RawFormat.Meta(
                sessionId: UUID(), sport: sport, startedAt: startUnix,
                device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"),
                app: .init(version: "0", build: "0"))
            return RawSession(meta: meta, motion: output.samples)
        }
        let canoe = SessionStats(session: session(.canoe))
        let strokes = try #require(canoe.strokes)
        #expect(abs(strokes.count - output.strokeCount) <= 1)
        #expect(strokes.sideSwitches == 0)
        #expect(strokes.distancePerStroke == nil)
        #expect(canoe.textReport().contains("Strokes   \(strokes.count), avg "))
        #expect(SessionStats(session: session(.sailing)).strokes == nil)
        #expect(SessionStats(session: session(.kayak)).strokes?.sideSwitches == nil)
    }

    @Test func simulatorIsDeterministic() {
        var simulator = PaddleMotionSimulator(sport: .canoe, segments: [Segment(duration: 10, strokeRate: 50)])
        simulator.seed = 41
        #expect(simulator.generate().samples == simulator.generate().samples)
        #expect(simulator.generate().strokeCount == 8)
    }
}
