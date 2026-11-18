import Foundation
import Testing

@testable import WaterKit

/// Regression tests for the PR #59 review findings.
@Suite struct StrokeReviewRegressionTests {
    /// A clean wrist rotation at `rate` cycles per minute about `axis`, at 100 Hz.
    func rotation(from start: Double, to end: Double, cyclesPerMinute rate: Double, axis: Vector3) -> [MotionSample] {
        stride(from: start, to: end, by: 0.01).map { t in
            let s = 2 * sin(2 * Double.pi * rate / 60 * (t - start))
            return MotionSample(
                t: t, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.8),
                rotationRate: Vector3(x: axis.x * s, y: axis.y * s, z: axis.z * s), attitude: .identity)
        }
    }

    func still(from start: Double, to end: Double) -> [MotionSample] {
        stride(from: start, to: end, by: 0.01).map { t in
            MotionSample(
                t: t, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.8), rotationRate: .zero,
                attitude: .identity)
        }
    }

    /// Finding 1: after a sensor gap, motion on an axis orthogonal to the old one must
    /// still be detected.
    @Test func detectionRecoversOnANewAxisAfterAGap() {
        var detector = StrokeDetector(sport: .sup)
        for sample in rotation(from: 0, to: 60, cyclesPerMinute: 60, axis: Vector3(x: 1, y: 0, z: 0)) {
            detector.ingest(sample)
        }
        let before = detector.snapshot.strokeCount
        #expect(abs(before - 60) <= 1)
        for sample in rotation(from: 63, to: 123, cyclesPerMinute: 60, axis: Vector3(x: 0, y: 1, z: 0)) {
            detector.ingest(sample)
        }
        #expect(abs(detector.snapshot.strokeCount - before - 60) <= 2)
        #expect(detector.snapshot.strokeRate.map { abs($0 - 60) <= 2 } == true)
    }

    /// Finding 1, without a gap: an abrupt change to an orthogonal axis.
    @Test func detectionFollowsAnOrthogonalAxisWithoutAGap() {
        var detector = StrokeDetector(sport: .sup)
        let samples =
            rotation(from: 0, to: 60, cyclesPerMinute: 60, axis: Vector3(x: 1, y: 0, z: 0))
            + rotation(from: 60, to: 120, cyclesPerMinute: 60, axis: Vector3(x: 0, y: 0, z: 1))
        for sample in samples { detector.ingest(sample) }
        #expect(abs(detector.snapshot.strokeCount - 120) <= 3)
    }

    /// Finding 4: a dropout must not be filled with the last value and turned into a stroke.
    @Test func dropoutAfterAPulseIsNotAStroke() {
        var pulse = still(from: 0, to: 10)
        for index in pulse.indices where (5.0..<5.04).contains(pulse[index].t) {
            pulse[index].rotationRate.x = 0.4
        }
        var baseline = StrokeDetector(sport: .sup)
        for sample in pulse { baseline.ingest(sample) }
        #expect(baseline.snapshot.strokeCount == 0)
        var detector = StrokeDetector(sport: .sup)
        for sample in pulse where !(5.04..<5.84).contains(sample.t) { detector.ingest(sample) }
        #expect(detector.snapshot.strokeCount == 0)
    }

    /// Finding 2: strokes taken while manually paused do not count, and the interval across
    /// the pause is not a stroke period. Auto-pause events (`auto: true`) do not stop counting.
    @Test func manualPauseStopsCounting() {
        let samples = rotation(from: 0, to: 90, cyclesPerMinute: 60, axis: Vector3(x: 1, y: 0, z: 0))
        let events = [
            SessionEvent(t: 30.1, type: .pause), SessionEvent(t: 40.1, type: .resume),
            SessionEvent(t: 60.1, type: .pause, data: ["auto": true]),
            SessionEvent(t: 70.1, type: .resume, data: ["auto": true]),
        ]
        let cycles = StrokeAnalysis.detect(motion: samples, sport: .sup, events: events).cycles
        #expect(cycles.allSatisfy { !(30.1..<40.1).contains($0.t) })
        #expect(cycles.contains { (60.1..<70.1).contains($0.t) })
        #expect(abs(cycles.count - 80) <= 2)
        #expect(cycles.first { $0.t >= 40.1 }?.period == nil)

        // Live: the same through `ingest(.event)`.
        var detector = StrokeDetector(sport: .sup)
        var pending = events[...]
        for sample in samples {
            while let event = pending.first, event.t <= sample.t {
                detector.ingest(.event(event))
                pending = pending.dropFirst()
            }
            detector.ingest(sample)
        }
        #expect(detector.snapshot.strokeCount == cycles.count)
    }

    /// Finding 3: kayak's inferred second stroke is filtered by the trim on its own time.
    @Test func kayakTrimFiltersExpandedStrokes() {
        let cycles = [
            StrokeDetector.Cycle(t: 8, period: nil, side: nil), StrokeDetector.Cycle(t: 10, period: 2, side: nil),
            StrokeDetector.Cycle(t: 12, period: 2, side: nil),
        ]
        let detection = StrokeAnalysis.Detection(
            cycles: cycles, strokes: StrokeAnalysis.expand(cycles, strokesPerCycle: 2))
        let ending = StrokeAnalysis(detection: detection, sport: .kayak, distance: nil, retained: [0...10.5])
        #expect(ending.strokes.map(\.t) == [8, 9, 10])
        let starting = StrokeAnalysis(detection: detection, sport: .kayak, distance: nil, retained: [10.5...20])
        #expect(starting.strokes.map(\.t) == [11, 12, 13])
    }
}
