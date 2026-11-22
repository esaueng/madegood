import Synchronization
import WaterKit
import XCTest

@testable import MadeGood

/// Regression tests for the PR #59 review: live strokes use one monotonic clock (device
/// uptime), and a manual pause stops counting.
final class LiveStrokesTests: XCTestCase {
    final class Uptime: Sendable {
        let value = Mutex(0.0)
        func set(_ t: Double) { value.withLock { $0 = t } }
        func read() -> Double { value.withLock { $0 } }
    }

    let startUptime = 1_000.0

    func motion(seconds: Double, rate: Double = 60) -> [MotionSample] {
        var simulator = PaddleMotionSimulator(sport: .sup, segments: [.init(duration: seconds, strokeRate: rate)])
        simulator.seed = 5
        return simulator.generate().samples
    }

    func feed(_ samples: [MotionSample], offset: Double = 0, to strokes: LiveStrokes, clock: Uptime) {
        for sample in samples {
            let ts = startUptime + offset + sample.t
            strokes.ingest(
                RawFormat.MotionLine(
                    ts: ts, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
                    rotationRate: sample.rotationRate, attitude: sample.attitude))
            clock.set(ts)
        }
    }

    /// Finding 5: the recorder checked freshness against wall time while peaks were on
    /// uptime, so a forward clock correction blanked the rate. The snapshot now reads only
    /// uptime; the wall clock is not an input.
    func testRateUsesUptimeNotTheWallClock() throws {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        feed(motion(seconds: 60), to: strokes, clock: clock)
        let rate = try XCTUnwrap(strokes.snapshot().strokeRate)
        XCTAssertEqual(rate, 60, accuracy: 2)
        // Paddling stops: the rate blanks on uptime alone.
        clock.set(clock.read() + 15)
        XCTAssertNil(strokes.snapshot().strokeRate)
        XCTAssertGreaterThan(strokes.snapshot().strokeCount, 50)
    }

    /// Finding 2: strokes during a manual pause are not counted.
    func testManualPauseStopsCounting() {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        let samples = motion(seconds: 90)
        feed(samples.filter { $0.t < 30 }, to: strokes, clock: clock)
        strokes.userEvent(.pause)
        feed(samples.filter { $0.t >= 30 && $0.t < 40 }, to: strokes, clock: clock)
        let paused = strokes.snapshot().strokeCount
        strokes.userEvent(.resume)
        feed(samples.filter { $0.t >= 40 }, to: strokes, clock: clock)
        // About 30 strokes before the pause (the last may finish just after it), none during
        // it, and about 50 after.
        XCTAssertEqual(Double(paused), 30, accuracy: 2)
        XCTAssertEqual(Double(strokes.snapshot().strokeCount - paused), 50, accuracy: 2)
    }

    /// The live count kept strokes in auto-pauses and vehicle legs, which session detail
    /// leaves out. Those intervals are on the engine's wall-time clock; strokes are placed on
    /// it with the clock anchors, so a wall clock set 100 s ahead at 60 s leaves the earlier
    /// pause where it was and moves only later strokes (review of PR #173).
    func testCountLeavesOutAutoPausedIntervalsAcrossAClockChange() {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        let samples = motion(seconds: 90)
        feed(samples.filter { $0.t < 60 }, to: strokes, clock: clock)
        // The wall clock jumps 100 s forward at 60 s; the recorder writes an anchor.
        strokes.anchor(mono: startUptime + 60, wall: startUptime + 160)
        feed(samples.filter { $0.t >= 60 }, to: strokes, clock: clock)
        let all = strokes.snapshot().strokeCount
        XCTAssertEqual(Double(all - strokes.snapshot(excluding: [20...40]).strokeCount), 20, accuracy: 2)
        // 70–80 s on the motion clock is 170–180 s on the wall clock.
        XCTAssertEqual(Double(all - strokes.snapshot(excluding: [170...180]).strokeCount), 10, accuracy: 2)
        XCTAssertEqual(strokes.snapshot(excluding: [70...80]).strokeCount, all)
        // An auto-pause still open leaves out everything after its start.
        XCTAssertEqual(Double(strokes.snapshot(excluding: [30...Double.infinity]).strokeCount), 30, accuracy: 2)
    }

    /// The final motion bin was never closed live, so a stroke confirmed in it was missing
    /// from the watch's summary; session detail closes it (review of PR #173).
    func testFinishCountsWhatSessionDetailCounts() {
        let samples = motion(seconds: 60)
        for end in stride(from: 30.0, through: 31.0, by: 0.04) {
            let clock = Uptime()
            let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
            let cut = samples.filter { $0.t < end }
            feed(cut, to: strokes, clock: clock)
            strokes.finish()
            XCTAssertEqual(
                strokes.snapshot().strokeCount, StrokeAnalysis.detect(motion: cut, sport: .sup).strokes.count,
                "ending at \(end) s")
        }
    }

    /// Review of #178: the first axis waits for a full 3 s window, so a session shorter than
    /// that counted no strokes live. `finish()` settles the axis from what there is.
    func testFinishCountsStrokesInASessionShorterThanTheAxisWindow() {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        let samples = motion(seconds: 2.5, rate: 50)
        XCTAssertLessThan(samples.last?.t ?? 0, 3)
        feed(samples, to: strokes, clock: clock)
        XCTAssertEqual(strokes.snapshot().strokeCount, 0)
        strokes.finish()
        let detail = StrokeAnalysis.detect(motion: samples, sport: .sup).strokes.count
        XCTAssertGreaterThan(detail, 0)
        XCTAssertEqual(strokes.snapshot().strokeCount, detail)
    }
}
